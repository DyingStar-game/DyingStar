using System;
using System.Collections.Generic;
using System.Threading.Channels;
using System.Threading.Tasks;
using System.Threading;
using System.Text.Json;
using System.Linq;
using Godot;


public class BatchOperationManager : IDisposable
{
    private readonly Func<Task<ITransaction>> _transactionFactory;
    private readonly BatchMutationConfig _config;
    private readonly Channel<IBatchOperationItem> _channel;

    private readonly System.Threading.Timer _flushTimer;
    private readonly SemaphoreSlim _adjustmentSemaphore;

    private BatchOperationStats _stats;
    private int _currentBatchSize;
    private bool _isRunning;
    private bool _disposed;

    private Task _batchTask;

    public BatchOperationStats Stats => _stats;

    public event Action<BatchOperationStats> OnStatsUpdated;
    public event Action<string> OnError;

    public BatchOperationManager(Func<Task<ITransaction>> transactionFactory, BatchMutationConfig config = null)
    {
        _transactionFactory = transactionFactory ?? throw new ArgumentNullException(nameof(transactionFactory));
        _config = config ?? new BatchMutationConfig();

        _channel = Channel.CreateBounded<IBatchOperationItem>(new BoundedChannelOptions(_config.ChannelCapacity)
        {
            FullMode = BoundedChannelFullMode.Wait,
            SingleReader = false,
            SingleWriter = false
        });

        _stats = new BatchOperationStats
        {
            CurrentBatchSize = _config.InitialBatchSize,
        };
        _currentBatchSize = _config.InitialBatchSize;

        _adjustmentSemaphore = new SemaphoreSlim(1, 1);

        // Timer pour forcer le flush périodique
        _flushTimer = new System.Threading.Timer(async _ => await ForceFlush(), null,
            _config.FlushInterval, _config.FlushInterval);
    }

    public async Task StartAsync()
    {
        if (_isRunning) return;

        _isRunning = true;

        _batchTask = Task.Run(ProcessBatchesAsync);

        GD.Print($"BatchOperationManager démarré ");
    }

    public async Task StopAsync()
    {
        if (!_isRunning) return;

        _isRunning = false;
        _channel.Writer.Complete();

        await Task.WhenAll(_batchTask);

        GD.Print("BatchOperationManager arrêté");
    }

    public async Task<bool> QueueOperationAsync(IBatchOperationItem item)
    {
        if (_disposed || !_isRunning) return false;

        try
        {
            await _channel.Writer.WriteAsync(item);
            return true;
        }
        catch (Exception ex)
        {
            OnError?.Invoke($"Erreur lors de l'ajout à la queue: {ex.Message}");
            return false;
        }
    }

    public async Task<bool> QueueMutationAsync(string jsonData, int priority = 5)
    {
        return await QueueOperationAsync(new BatchMutationItem(jsonData, priority));
    }

    public async Task<bool> QueueDeletionAsync(string jsonData, int priority = 5)
    {
        return await QueueOperationAsync(new BatchDeletionItem(jsonData, priority));
    }

    private async Task ProcessBatchesAsync()
    {
        var batchBuffer = new List<IBatchOperationItem>();
        var lastFlush = DateTime.UtcNow;

        try
        {
            await foreach (var item in _channel.Reader.ReadAllAsync())
            {
                if (!_isRunning) break;

                batchBuffer.Add(item);

                // Conditions de flush du batch
                bool shouldFlush = batchBuffer.Count >= _currentBatchSize ||
                                 DateTime.UtcNow - lastFlush > _config.FlushInterval ||
                                 batchBuffer.Any(x => x.Priority == 0); // Items haute priorité

                if (shouldFlush && batchBuffer.Count > 0)
                {
                    await ProcessBatch(batchBuffer.ToList());
                    batchBuffer.Clear();
                    lastFlush = DateTime.UtcNow;
                }
            }

            // Traiter les derniers éléments
            if (batchBuffer.Count > 0)
            {
                await ProcessBatch(batchBuffer);
            }
        }
        catch (Exception ex)
        {
            OnError?.Invoke($"Erreur : {ex.Message}");
        }
    }

    private async Task ProcessBatch(List<IBatchOperationItem> batch)
    {
        if (batch.Count == 0) return;

        // Séparer les mutations et les suppressions
        var mutations = batch.Where(x => x.OperationType == BatchOperationType.Mutation).ToList();
        var deletions = batch.Where(x => x.OperationType == BatchOperationType.Deletion).ToList();

        // Trier chaque groupe par priorité (0 = plus haute priorité)
        mutations.Sort((x, y) => x.Priority.CompareTo(y.Priority));
        deletions.Sort((x, y) => x.Priority.CompareTo(y.Priority));

        int attempt = 0;
        bool success = false;
        int delay = _config.BaseDelayMs;

        while (!success && attempt < _config.MaxRetries)
        {
            attempt++;

            using var transaction = await _transactionFactory();
            try
            {
                // Traiter les mutations d'abord (si il y en a)
                if (mutations.Count > 0)
                {
                    string mutationJson = CombineJsonOperations(mutations);

                    var mutateResult = await transaction.MutateAsync(mutationJson);
                    if (!mutateResult.IsSuccess)
                    {
                        throw new Exception($"mutate failed: {mutateResult.ErrorMessage}");
                    }
                }

                // Traiter les suppressions ensuite (si il y en a)
                if (deletions.Count > 0)
                {
                    string deletionJson = CombineJsonOperations(deletions);
                    var deleteResult = await transaction.DeleteAsync(deletionJson);

                    if (!deleteResult.IsSuccess)
                    {
                        throw new Exception($"Delete failed: {deleteResult.ErrorMessage}");
                    }
                }

                await transaction.CommitAsync();

                success = true;
                _stats.IncrementSuccessfulBatches();
                _stats.AddMutationsProcessed(mutations.Count);
                _stats.AddDeletionsProcessed(deletions.Count);
                _stats.LastFlush = DateTime.UtcNow;

                GD.Print($"Batch traité avec succès: {mutations.Count} mutations, {deletions.Count} suppressions (tentative {attempt})");
            }
            catch (Exception ex)
            {
                _stats.IncrementAbordedBatches();

                if (attempt < _config.MaxRetries)
                {
                    GD.PrintErr($"Échec du batch (tentative {attempt}), retry dans {delay}ms: {ex.Message}");
                    await Task.Delay(delay);
                    delay *= 2;
                }
                else
                {
                    GD.PrintErr($"Échec définitif du batch après {_config.MaxRetries} tentatives: {ex.Message}");
                    OnError?.Invoke($"Batch failed permanently: {ex.Message}");
                }
            }
            finally
            {
                try
                {
                    await transaction.DiscardAsync();
                }
                catch (Exception ex)
                {
                    GD.PrintErr($"Erreur lors du discard: {ex.Message}");
                }
            }
        }

        // Ajustement adaptatif de la taille des batches
        await AdjustBatchSizeAsync();

        // Notifier les statistiques
        OnStatsUpdated?.Invoke(_stats);
    }

    private string CombineJsonOperations(List<IBatchOperationItem> operations)
    {
        try
        {
            var allOperations = new List<object>();

            foreach (var item in operations)
            {
                // Parser le JSON de chaque élément
                var jsonElement = JsonSerializer.Deserialize<JsonElement>(item.JsonData);

                if (jsonElement.ValueKind == JsonValueKind.Array)
                {
                    // Si c'est déjà un tableau, ajouter tous les éléments
                    foreach (var element in jsonElement.EnumerateArray())
                    {
                        allOperations.Add(JsonSerializer.Deserialize<object>(element.GetRawText()));
                    }
                }
                else
                {
                    // Si c'est un objet unique, l'ajouter directement
                    allOperations.Add(JsonSerializer.Deserialize<object>(item.JsonData));
                }
            }

            // Retourner le tableau combiné en JSON
            return JsonSerializer.Serialize(allOperations);
        }
        catch (Exception ex)
        {
            GD.PrintErr($"Erreur lors de la combinaison des JSON: {ex.Message}");

            // Fallback: combiner les JSON bruts dans un tableau
            var jsonStrings = operations.Select(b => b.JsonData.Trim()).ToList();

            // Nettoyer et combiner
            var cleanedJsons = new List<string>();
            foreach (var json in jsonStrings)
            {
                if (json.StartsWith("[") && json.EndsWith("]"))
                {
                    // C'est un tableau, enlever les crochets et ajouter les éléments
                    var innerJson = json.Substring(1, json.Length - 2).Trim();
                    if (!string.IsNullOrEmpty(innerJson))
                    {
                        cleanedJsons.Add(innerJson);
                    }
                }
                else
                {
                    // C'est un objet unique
                    cleanedJsons.Add(json);
                }
            }

            return $"[{string.Join(",", cleanedJsons)}]";
        }
    }

    private async Task AdjustBatchSizeAsync()
    {
        await _adjustmentSemaphore.WaitAsync();

        try
        {
            double successRate = _stats.SuccessRate;
            long totalBatches = _stats.SuccessfulBatches + _stats.AbortedBatches;

            if (totalBatches < 10) return; // Pas assez de données

            if (successRate < 80 && _currentBatchSize > _config.MinBatchSize)
            {
                // Trop d'échecs, réduire la taille des batches
                _currentBatchSize = Math.Max(_currentBatchSize / 2, _config.MinBatchSize);
                _stats.CurrentBatchSize = _currentBatchSize;
                GD.Print($"⚠️ Taux de succès {successRate:F1}%, réduction batchSize à {_currentBatchSize}");
            }
            else if (successRate > 95 && _currentBatchSize < _config.MaxBatchSize &&
                     _stats.SuccessfulBatches % 20 == 0) // Ajustement moins fréquent vers le haut
            {
                // Très bon taux de succès, augmenter la taille
                _currentBatchSize = Math.Min(_currentBatchSize + 50, _config.MaxBatchSize);
                _stats.CurrentBatchSize = _currentBatchSize;
                GD.Print($"✅ Excellent taux de succès {successRate:F1}%, augmentation batchSize à {_currentBatchSize}");
            }
        }
        finally
        {
            _adjustmentSemaphore.Release();
        }
    }

    private async Task ForceFlush()
    {
        if (_disposed || !_isRunning) return;

        // Cette méthode peut être utilisée pour forcer le traitement des batches en attente
        _stats.LastFlush = DateTime.UtcNow;
    }

    public void Dispose()
    {
        if (_disposed) return;

        _disposed = true;

        try
        {
            _flushTimer?.Dispose();
            _adjustmentSemaphore?.Dispose();

            if (_isRunning)
            {
                StopAsync().Wait(TimeSpan.FromSeconds(10));
            }
        }
        catch (Exception ex)
        {
            GD.PrintErr($"Erreur lors du dispose: {ex.Message}");
        }
    }
}