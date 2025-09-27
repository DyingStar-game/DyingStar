// Types d'opérations
using System;
using System.Threading;

public enum BatchOperationType
{
    Mutation,
    Deletion
}

// Interface pour les éléments à traiter en batch
public interface IBatchOperationItem
{
    string JsonData { get; }
    BatchOperationType OperationType { get; }
    int Priority { get; } // 0 = haute priorité, plus élevé = basse priorité
}

// Implémentation d'un élément d'opération (mutation ou delete)
public class BatchOperationItem : IBatchOperationItem
{
    public string JsonData { get; set; }
    public BatchOperationType OperationType { get; set; }
    public int Priority { get; set; } = 5; // priorité normale

    public BatchOperationItem(string jsonData, BatchOperationType operationType, int priority = 5)
    {
        JsonData = jsonData ?? throw new ArgumentNullException(nameof(jsonData));
        OperationType = operationType;
        Priority = priority;
    }
}

// Classes de commodité
public class BatchMutationItem : BatchOperationItem
{
    public BatchMutationItem(string jsonData, int priority = 5)
        : base(jsonData, BatchOperationType.Mutation, priority) { }
}

public class BatchDeletionItem : BatchOperationItem
{
    public BatchDeletionItem(string jsonData, int priority = 5)
        : base(jsonData, BatchOperationType.Deletion, priority) { }
}

// Configuration du système de batch
public class BatchMutationConfig
{
    public int InitialBatchSize { get; set; } = 100;
    public int MinBatchSize { get; set; } = 10;
    public int MaxBatchSize { get; set; } = 500;
    public int MaxRetries { get; set; } = 3;
    public int BaseDelayMs { get; set; } = 50;
    public int ChannelCapacity { get; set; } = 1000;
    public TimeSpan FlushInterval { get; set; } = TimeSpan.FromSeconds(5);
}

// Statistiques du système
public class BatchOperationStats
{
    private long _successfulBatches;
    private long _abortedBatches;
    private long _totalMutationsProcessed;
    private long _totalDeletionsProcessed;
    public long SuccessfulBatches => _successfulBatches;
    public long AbortedBatches => _abortedBatches;
    public long TotalMutationsProcessed => _totalMutationsProcessed;
    public long TotalDeletionsProcessed => _totalDeletionsProcessed;
    public int CurrentBatchSize { get; set; }

    public DateTime LastFlush { get; set; }

    public long TotalItemsProcessed => TotalMutationsProcessed + TotalDeletionsProcessed;

    public double SuccessRate =>
        SuccessfulBatches + AbortedBatches == 0 ? 100.0 :
        (double)SuccessfulBatches / (SuccessfulBatches + AbortedBatches) * 100.0;

    public void IncrementSuccessfulBatches() =>
        Interlocked.Increment(ref _successfulBatches);

    public void IncrementAbordedBatches() =>
        Interlocked.Increment(ref _abortedBatches);

    public void AddMutationsProcessed(long count) =>
        Interlocked.Add(ref _totalMutationsProcessed, count);

    public void AddDeletionsProcessed(long count) =>
        Interlocked.Add(ref _totalDeletionsProcessed, count);
}