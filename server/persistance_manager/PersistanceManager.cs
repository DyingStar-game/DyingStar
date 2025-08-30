using Godot;
using System;
using System.Threading.Tasks;

public partial class PersistanceManager : Node
{
    [Signal]
    public delegate void ClientReadyEventHandler();
    
    [Signal]
    public delegate void SaveCompletedEventHandler(bool success, string uid, string errorMessage, string requestId);
    
    [Signal]
    public delegate void DeleteCompletedEventHandler(bool success, string errorMessage, string requestId);
    
    [Signal]
    public delegate void QueryCompletedEventHandler(bool success, string jsonData, string errorMessage, string requestId);
    
    [Signal]
    public delegate void FindByIdCompletedEventHandler(bool success, string jsonData, string errorMessage, string requestId);

    private static IPersistenceProvider _persistenceProvider;

    public static PersistanceManager Instance { get; private set; }
    private ConfigFile _configFile = new ConfigFile();
    private bool _enabled = false;

    public bool IsReady { get; private set; } = false;

    const string SECTION_CONF = "persistance";

    private BatchOperationManager _batchManager;
 
    public override void _Ready()
    {
        if (Godot.OS.HasFeature("dedicated_server"))
        {
          Instance = this;
          InitializeAsync();
        }
       
    }



    private async void InitializeAsync()
    {
        try
        {
            GD.Print("🔄 Start Abstracted Persistence Manager");
            _configFile.Load("res://server.ini");

            if (_configFile.GetValue(SECTION_CONF, "enabled").AsBool())
            {
                _enabled = true;

                var dbType = _configFile.GetValue(SECTION_CONF, "type", "dgraph").AsString();
                var dbHost = _configFile.GetValue(SECTION_CONF, "DBHost").AsString();

                _persistenceProvider = CreateProvider(dbType, dbHost);

                if (await _persistenceProvider.InitializeAsync())
                {
                    GD.Print("✅ Database connection established");
                    string path = "res://server/persistance_manager/database.schema";
                    if (FileAccess.FileExists(path))
                    {
                        using var file = FileAccess.Open(path, FileAccess.ModeFlags.Read);
                        string content = file.GetAsText();
                        var isapply = await _persistenceProvider.ApplySchemaAsync(content);
                        GD.Print(isapply);
                        if (isapply){
                            GD.Print("✅ Database schema apply");
                        }
                    }
                    else
                    {
                        GD.PrintErr($"File not found: {path}");
                    }
                   
                    IsReady = true;
                    EmitSignal(nameof(ClientReady));
                    await batchInitializeAsync();
                }
                else
                {
                    GD.PrintErr("❌ Failed to initialize database connection");
                    _enabled = false;
                }
                
            }
        }
        catch (Exception ex)
        {
            GD.PrintErr($"❌ An error occurred in _Ready: {ex.Message}");
            _enabled = false;
        }
    }

    private async Task batchInitializeAsync()
    {
        try
        {
            // Configuration personnalisée
            var config = new BatchMutationConfig
            {
                InitialBatchSize = 200,
                MinBatchSize = 20,
                MaxBatchSize = 1000,
                MaxRetries = 3,
                FlushInterval = TimeSpan.FromSeconds(2)
            };

            _batchManager = new BatchOperationManager(
                () => _persistenceProvider.BeginTransactionAsync(),
                config
            );
            
            // Écouter les événements
            _batchManager.OnStatsUpdated += stats => 
            {
                GD.Print($"Stats: {stats.TotalItemsProcessed} items ({stats.TotalMutationsProcessed} mutations, {stats.TotalDeletionsProcessed} suppressions), {stats.SuccessRate:F1}% succès, batch={stats.CurrentBatchSize}");
            };
            
            _batchManager.OnError += error => 
            {
                GD.PrintErr($"Erreur batch: {error}");
            };

            await _batchManager.StartAsync();
        }
        catch (Exception ex)
        {
            GD.PrintErr($"❌ An error occurred in _Ready: {ex.Message}");
            _enabled = false;
        }
    }

    // ============ SAVE OPERATIONS ============
    public string SaveObjAsync(string obj, string requestId = "")
    {
        if (string.IsNullOrEmpty(requestId))
        {
            requestId = System.Guid.NewGuid().ToString();
        }

        GD.Print($"🔄 Starting async save with request ID: {requestId}");

        _ = System.Threading.Tasks.Task.Run(async () =>
        {
            try 
            {
                var result = await SaveAsync(obj);
                CallDeferred(nameof(EmitSaveCompleted), result.IsSuccess, result.Uid ?? "", result.ErrorMessage ?? "", requestId);
            }
            catch (System.Exception ex)
            {
                GD.PrintErr($"❌ Exception during async save: {ex.Message}");
                CallDeferred(nameof(EmitSaveCompleted), false, "", ex.Message, requestId);
            }
        });

        return requestId;
    }

    public string StartSaveAsync(string obj)
    {
        var requestId = System.Guid.NewGuid().ToString();
        SaveObjAsync(obj, requestId);
        return requestId;
    }

    private void EmitSaveCompleted(bool success, string uid, string errorMessage, string requestId)
    {
        if (success)
        {
            GD.Print($"✅ Save executed successfully with UID: {uid}");
        }
        else
        {
            GD.PrintErr($"❌ Save failed: {errorMessage}");
        }
        
        EmitSignal(nameof(SaveCompleted), success, uid, errorMessage, requestId);
    }

    public void BackgroundSaveObjAsync(string obj, int priority)
    {
       
        GD.Print($"🔄 Starting async background save ");

        _ = System.Threading.Tasks.Task.Run(async () =>
        {
            try 
            {
                await _batchManager.QueueMutationAsync(obj, priority);
            }
            catch (System.Exception ex)
            {
                GD.PrintErr($"❌ Exception during async backgroud save: {ex.Message}");
            }
        });
    }

    // ============ DELETE OPERATIONS ============
    public string DeleteObjAsync(string uid, string requestId = "")
    {
        if (string.IsNullOrEmpty(requestId))
        {
            requestId = System.Guid.NewGuid().ToString();
        }

        GD.Print($"🔄 Starting async delete with request ID: {requestId}");

        _ = System.Threading.Tasks.Task.Run(async () =>
        {
            try 
            {
                var result = await DeleteAsync(uid);
                CallDeferred(nameof(EmitDeleteCompleted), result.IsSuccess, result.ErrorMessage ?? "", requestId);
            }
            catch (System.Exception ex)
            {
                GD.PrintErr($"❌ Exception during async delete: {ex.Message}");
                CallDeferred(nameof(EmitDeleteCompleted), false, ex.Message, requestId);
            }
        });

        return requestId;
    }

    public string StartDeleteAsync(string uid)
    {
        var requestId = System.Guid.NewGuid().ToString();
        DeleteObjAsync(uid, requestId);
        return requestId;
    }

    private void EmitDeleteCompleted(bool success, string errorMessage, string requestId)
    {
        if (success)
        {
            GD.Print($"✅ Delete executed successfully");
        }
        else
        {
            GD.PrintErr($"❌ Delete failed: {errorMessage}");
        }
        
        EmitSignal(nameof(DeleteCompleted), success, errorMessage, requestId);
    }

    public void BackgroundDeleteObjAsync(string uid, int priority)
    {
       
        GD.Print($"🔄 Starting async background save ");

        _ = System.Threading.Tasks.Task.Run(async () =>
        {
            try 
            {
                await _batchManager.QueueDeletionAsync(uid, priority);
            }
            catch (System.Exception ex)
            {
                GD.PrintErr($"❌ Exception during async backgroud save: {ex.Message}");
            }
        });
    }
    // ============ QUERY OPERATIONS ============
    public string QueryAsync(string queryString, string requestId = "")
    {
        if (string.IsNullOrEmpty(requestId))
        {
            requestId = System.Guid.NewGuid().ToString();
        }

        GD.Print($"🔄 Starting async query with request ID: {requestId}");

        _ = System.Threading.Tasks.Task.Run(async () =>
        {
            try 
            {
                var result = await ExecuteQueryAsync(queryString);
                CallDeferred(nameof(EmitQueryCompleted), result.IsSuccess, result.Data ?? "", result.ErrorMessage ?? "", requestId);
            }
            catch (System.Exception ex)
            {
                GD.PrintErr($"❌ Exception during async query: {ex.Message}");
                CallDeferred(nameof(EmitQueryCompleted), false, "", ex.Message, requestId);
            }
        });

        return requestId;
    }

    public string StartQueryAsync(string queryString)
    {
        var requestId = System.Guid.NewGuid().ToString();
        QueryAsync(queryString, requestId);
        return requestId;
    }

    private void EmitQueryCompleted(bool success, string jsonData, string errorMessage, string requestId)
    {
        if (success)
        {
            GD.Print($"✅ Query executed successfully");
        }
        else
        {
            GD.PrintErr($"❌ Query failed: {errorMessage}");
        }
        
        EmitSignal(nameof(QueryCompleted), success, jsonData, errorMessage, requestId);
    }

    // ============ FIND BY ID OPERATIONS ============
    public string FindByIdAsync(string uid, string requestId = "")
    {
        if (string.IsNullOrEmpty(requestId))
        {
            requestId = System.Guid.NewGuid().ToString();
        }

        GD.Print($"🔄 Starting async find by ID with request ID: {requestId}");

        _ = System.Threading.Tasks.Task.Run(async () =>
        {
            try 
            {
                var result = await FindByIdInternalAsync(uid);
                CallDeferred(nameof(EmitFindByIdCompleted), result.IsSuccess, result.Data ?? "", result.ErrorMessage ?? "", requestId);
            }
            catch (System.Exception ex)
            {
                GD.PrintErr($"❌ Exception during async find by ID: {ex.Message}");
                CallDeferred(nameof(EmitFindByIdCompleted), false, "", ex.Message, requestId);
            }
        });

        return requestId;
    }

    public string StartFindByIdAsync(string id)
    {
        var requestId = System.Guid.NewGuid().ToString();
        FindByIdAsync(id, requestId);
        return requestId;
    }

    private void EmitFindByIdCompleted(bool success, string jsonData, string errorMessage, string requestId)
    {
        if (success)
        {
            GD.Print($"✅ Find by ID executed successfully");
        }
        else
        {
            GD.PrintErr($"❌ Find by ID failed: {errorMessage}");
        }
        
        EmitSignal(nameof(FindByIdCompleted), success, jsonData, errorMessage, requestId);
    }

    private IPersistenceProvider CreateProvider(string dbType, string connectionString)
    {
        return dbType.ToLower() switch
        {
            "dgraph" => new DgraphPersistenceProvider(connectionString),
            _ => throw new NotSupportedException($"Database type '{dbType}' is not supported")
        };
    }

    // ============ INTERNAL ASYNC METHODS ============
    
    public async Task<OperationResultWithUid> SaveAsync(string entity)
    {
        if (!_enabled) return OperationResultWithUid.Failure("Database not enabled");

        using var transaction = await _persistenceProvider.BeginTransactionAsync();
        var mutateResult = await transaction.MutateAsync(entity);

        var uid = mutateResult.Uid;
        if (mutateResult.IsSuccess)
        {
            var commitResult = await transaction.CommitAsync();
            return commitResult.IsSuccess
                ? OperationResultWithUid.Success("Entity saved successfully", uid)
                : OperationResultWithUid.Failure(commitResult.ErrorMessage);
        }
        return OperationResultWithUid.Failure("Mutation failed");
    }

    public async Task<OperationResult> DeleteAsync(string deleteObj)
    {
        if (!_enabled) return OperationResult.Failure("Database not enabled");

        using var transaction = await _persistenceProvider.BeginTransactionAsync();
        
        // Construire l'objet de suppression
        var deleteResult = await transaction.DeleteAsync(deleteObj);

        if (deleteResult.IsSuccess)
        {
            var commitResult = await transaction.CommitAsync();
            return commitResult.IsSuccess
                ? OperationResult.Success()
                : OperationResult.Failure(commitResult.ErrorMessage);
        }
        return OperationResult.Failure("Delete failed");
    }

    public async Task<IOperationResultData> ExecuteQueryAsync(string queryString)
    {
        if (!_enabled) return OperationResultData.Failure("Database not enabled");

        using var transaction = await _persistenceProvider.BeginReadOnlyTransactionAsync();
        return await transaction.QueryAsync(queryString);
    }

    public async Task<IOperationResultData> FindByIdInternalAsync(string uid)
    {
        if (!_enabled) return OperationResultData.Failure("Database not enabled");

        using var transaction = await _persistenceProvider.BeginReadOnlyTransactionAsync();
        var query = $"{{ entity(func: uid({uid})) {{ expand(_all_) }} }}";
        return await transaction.QueryAsync(query);
    }

    public async override void _ExitTree()
    {
        _persistenceProvider?.Dispose();
        if (_batchManager != null)
        {
            await _batchManager.StopAsync();
            _batchManager.Dispose();
        }
    }

    public override void _Process(double delta)
    {
        // Logique de traitement si nécessaire
    }
}