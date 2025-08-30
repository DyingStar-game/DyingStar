using System;
using System.IO.Compression;
using System.Net.Http;
using System.Threading.Tasks;
using Dgraph;
using Godot;
using Grpc.Net.Client;
using Grpc.Net.Compression;

public class DgraphPersistenceProvider : IPersistenceProvider
{
    private DgraphClient _client;
    private GrpcChannel _channel;
    private readonly string _connectionString;

    public DgraphPersistenceProvider(string connectionString)
    {
        _connectionString = connectionString;
    }

    public async Task<bool> InitializeAsync()
    {
        try
        {
            // Enable HTTP/2 without TLS
            AppContext.SetSwitch("System.Net.Http.SocketsHttpHandler.Http2UnencryptedSupport", true);

            var handler = new SocketsHttpHandler()
            {
                EnableMultipleHttp2Connections = true,
                KeepAlivePingDelay = TimeSpan.FromSeconds(60),
                KeepAlivePingTimeout = TimeSpan.FromSeconds(30),
                KeepAlivePingPolicy = HttpKeepAlivePingPolicy.WithActiveRequests
            };

            var httpClient = new System.Net.Http.HttpClient(handler)
            {
                Timeout = TimeSpan.FromSeconds(100)
            };


            var options = new GrpcChannelOptions
            {
                HttpClient = httpClient,
                MaxReceiveMessageSize = 64 * 1024 * 1024, // 64 MiB
                MaxSendMessageSize = 64 * 1024 * 1024,
                ThrowOperationCanceledOnCancellation = true,
                CompressionProviders = new[] { new GzipCompressionProvider(CompressionLevel.Optimal) },
            };
            _channel = GrpcChannel.ForAddress(_connectionString, options);
            _client = new DgraphClient(_channel);
            
            return await TestConnectionAsync();
        }
        catch (Exception)
        {
            return false;
        }
    }

    public async Task<bool> TestConnectionAsync()
    {
        try
        {
            using var transaction = await BeginReadOnlyTransactionAsync();
            var result = await transaction.QueryAsync("schema {}");
            return result.IsSuccess;
        }
        catch
        {
            return false;
        }
    }

    public async Task<bool> ApplySchemaAsync(string schema)
    {

            var operation = new Api.Operation { Schema = schema };
            var result = await _client.Alter(operation);
            if (result.IsSuccess) {
                return true;
            } else {
                 GD.PrintErr(result.Errors[0].Message);
                return false;
            }
    }
    public Task<ITransaction> BeginTransactionAsync()
    {
        var dgraphTransaction = _client.NewTransaction();
        return Task.FromResult<ITransaction>(new DgraphTransactionWrapper(dgraphTransaction));
    }

    public Task<IReadOnlyTransaction> BeginReadOnlyTransactionAsync()
    {
        var dgraphTransaction = _client.NewReadOnlyTransaction();
        return Task.FromResult<IReadOnlyTransaction>(new DgraphReadOnlyTransactionWrapper(dgraphTransaction));
    }

    public void Dispose()
    {
        _client?.Dispose();
        _channel?.Dispose();
    }
}