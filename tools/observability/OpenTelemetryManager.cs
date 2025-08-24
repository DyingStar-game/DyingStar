
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Diagnostics.Metrics;
using System.Text.Json;
using System.Threading.Tasks;
using Godot;
using Microsoft.Extensions.Logging;
using OpenTelemetry;
using OpenTelemetry.Logs;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

public partial class OpenTelemetryManager : Node
{
    public static OpenTelemetryManager Instance { get; private set; }
    private const string SERVICE_NAME = "StarDeceptionGameEngine";
    private const string SERVICE_VERSION = "0.0.1";

    // Sources pour tracing et metrics
    private static readonly ActivitySource ActivitySource = new(SERVICE_NAME);
    private static readonly Meter Meter = new(SERVICE_NAME, SERVICE_VERSION);
    
// Métriques
    private static readonly Counter<int> RequestCounter = 
        Meter.CreateCounter<int>("requests.count", "requests", "Total requests");
    
    private static readonly Histogram<double> RequestDuration = 
        Meter.CreateHistogram<double>("requests.duration", "ms", "Request duration");

    // Logger factory global
    private static ILoggerFactory? _loggerFactory;
    private static ILogger? _logger;

     public override void _Ready()
    {
        Instance = this;
        InitializeAsync();
    }
    static async void InitializeAsync()
    {
        // Configuration des ressources
        var resourceBuilder = ResourceBuilder.CreateDefault()
            .AddService(SERVICE_NAME, SERVICE_VERSION)
            .AddAttributes(new[]
            {
                new KeyValuePair<string, object>("environment", "production"),
                new KeyValuePair<string, object>("team", "backend")
            });

        // Configuration Logging avec JSON
        _loggerFactory = LoggerFactory.Create(builder =>
        {
            // JSON Console
            builder.AddJsonConsole(options =>
            {
                options.IncludeScopes = true;
                options.TimestampFormat = "yyyy-MM-ddTHH:mm:ss.fffZ";
                options.JsonWriterOptions = new JsonWriterOptions { Indented = false };
            });

            // OpenTelemetry
            builder.AddOpenTelemetry(options =>
            {
                options.SetResourceBuilder(resourceBuilder);
                options.IncludeScopes = true;
                options.IncludeFormattedMessage = true;
                options.AddOtlpExporter(otlp =>
                {
                    otlp.Endpoint = new Uri("http://localhost:4317");
                });
            });

            builder.SetMinimumLevel(LogLevel.Debug);
        });

        _logger = _loggerFactory.CreateLogger<OpenTelemetryManager>();

        // Configuration Tracing
        using var tracerProvider = Sdk.CreateTracerProviderBuilder()
            .SetResourceBuilder(resourceBuilder)
            .AddSource(SERVICE_NAME)
            .AddOtlpExporter(options => options.Endpoint = new Uri("http://localhost:4317"))
            .Build();

        // Configuration Metrics
        using var meterProvider = Sdk.CreateMeterProviderBuilder()
            .SetResourceBuilder(resourceBuilder)
            .AddMeter(SERVICE_NAME)
            .AddOtlpExporter(options => options.Endpoint = new Uri("http://localhost:4317"))
            .Build();
        var section = "testsection";
        _logger.LogInformation("log de test",section);

    }


    static async Task RunExamples()
    {
        // Exemple 1: Log simple avec contexte
        using (_logger!.BeginScope("UserId={UserId}", "user123"))
        {
            _logger.LogInformation("User login: username={Username} ip={IP}", 
                "john.doe", "192.168.1.100");
        }

        // Exemple 2: Trace avec métriques
        using var activity = ActivitySource.StartActivity("ProcessOrder");
        activity?.SetTag("order.id", "order-456");
        activity?.SetTag("customer.id", "cust-789");

        var stopwatch = Stopwatch.StartNew();

        try
        {
            _logger!.LogInformation("Processing order: order_id={OrderId} customer_id={CustomerId}", 
                "order-456", "cust-789");

            // Simule du travail
            await Task.Delay(100);

            // Simule une étape
            await ProcessPayment("order-456", 99.99m);

            stopwatch.Stop();

            // Métriques
            RequestCounter.Add(1, new KeyValuePair<string, object?>("operation", "process_order"));
            RequestDuration.Record(stopwatch.Elapsed.TotalMilliseconds, new KeyValuePair<string, object?>("operation", "process_order"));

            _logger.LogInformation("Order processed successfully: order_id={OrderId} duration={Duration}ms", 
                "order-456", stopwatch.Elapsed.TotalMilliseconds);

            activity?.SetStatus(ActivityStatusCode.Ok);
        }
        catch (Exception ex)
        {
            activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
            _logger!.LogError(ex, "Order processing failed: order_id={OrderId}", "order-456");
        }

        // Exemple 3: Logs d'erreur
        try
        {
            throw new InvalidOperationException("Simulated error");
        }
        catch (Exception ex)
        {
            _logger!.LogError(ex, "Database error: host={Host} database={Database} query={Query}", 
                "db.example.com", "orders", "SELECT * FROM orders");
        }

        // Exemple 4: Log de métrique business
        _logger!.LogInformation("Daily stats: date={Date} orders={Orders} revenue={Revenue} currency={Currency}", 
            DateOnly.FromDateTime(DateTime.Today), 156, 15420.50m, "EUR");
    }

    static async Task ProcessPayment(string orderId, decimal amount)
    {
        using var activity = ActivitySource.StartActivity("ProcessPayment");
        activity?.SetTag("payment.amount", amount);
        activity?.SetTag("payment.currency", "EUR");

        using (_logger!.BeginScope("OrderId={OrderId}", orderId))
        {
            _logger.LogDebug("Starting payment processing: amount={Amount} currency={Currency}", 
                amount, "EUR");

            // Simule traitement paiement
            await Task.Delay(50);

            _logger.LogInformation("Payment completed: amount={Amount} currency={Currency} gateway={Gateway}", 
                amount, "EUR", "stripe");
        }
    }
    public async override void _ExitTree()
    {
        // Cleanup
        _loggerFactory?.Dispose();
        ActivitySource.Dispose();
        Meter.Dispose();
    }

}
