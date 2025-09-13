
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Diagnostics.Metrics;
using System.Text.Json;
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

    private static ConfigFile _configFile = new ConfigFile();

    private static bool _enabled = false;

    private const string SERVICE_NAME = "DyingStar";
    private const string SERVICE_TYPE = "GameEngine";

    private const string SECTION_CONF = "observability";
    private static bool isServer = false;

    private static LogLevelType CurrentLevel = LogLevelType.Trace;

    // Sources pour tracing et metrics
    private static readonly ActivitySource ActivitySource = new(SERVICE_NAME);
    private static readonly Meter Meter = new(SERVICE_NAME, SERVICE_TYPE);

    // Métriques & Trace Dynamic
    private static readonly Dictionary<string, object> DynamicMetrics = new();

    private static readonly Dictionary<string, Activity> ActiveActivities = new();

    // Logger factory global
    private static ILoggerFactory _loggerFactory;
    private static ILogger _logger;

    public override void _Ready()
    {
        Instance = this;
        if (Godot.OS.HasFeature("dedicated_server"))
        {
            isServer = true;
        }
        InitializeAsync();
    }
    static void InitializeAsync()
    {
        try
        {
            // Configuration des ressources
            var resourceBuilder = ResourceBuilder.CreateDefault()
                .AddService(SERVICE_NAME, SERVICE_TYPE);


            if (isServer)
            {
                _configFile.Load("res://server.ini");
                resourceBuilder.AddAttributes(
                    new[]
                    {
                    new KeyValuePair<string, object>("origin", "server"),
                    }
                );
            }
            else
            {
                _configFile.Load("res://client.ini");
                resourceBuilder.AddAttributes(
                   new[]
                   {
                    new KeyValuePair<string, object>("origin", "client"),
                   }
               );
            }
            if (!Enum.TryParse<LogLevelType>(_configFile.GetValue(SECTION_CONF, "level").AsString(), true, out var confLevel))
                confLevel = LogLevelType.Information;
            CurrentLevel = confLevel;
            resourceBuilder.AddAttributes(new[]
            {
            new KeyValuePair<string, object>("environment", _configFile.GetValue(SECTION_CONF, "environnement").AsString()),
        });
            if (_configFile.GetValue(SECTION_CONF, "enabled").AsBool())
            {
                _enabled = true;
                var uri = new Uri(_configFile.GetValue(SECTION_CONF, "collectorHost").AsString());

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
                            otlp.Endpoint = uri;
                            otlp.BatchExportProcessorOptions = new()
                            {
                                MaxExportBatchSize = 512,
                                ScheduledDelayMilliseconds = 5000
                            };
                        });
                    });

                    builder.SetMinimumLevel(LogLevel.Debug);
                });

                _logger = _loggerFactory.CreateLogger<OpenTelemetryManager>();

                // Configuration Tracing
                using var tracerProvider = Sdk.CreateTracerProviderBuilder()
                    .SetResourceBuilder(resourceBuilder)
                    .AddSource(SERVICE_NAME)
                    .AddOtlpExporter(options =>
                    {
                        options.Endpoint = uri;
                        options.BatchExportProcessorOptions = new()
                        {
                            MaxExportBatchSize = 512, // nombre max d’éléments par batch
                            ScheduledDelayMilliseconds = 5000, // délai max avant envoi (5s)
                            ExporterTimeoutMilliseconds = 30000 // timeout
                        };
                    })
                    .Build();

                // Configuration Metrics
                using var meterProvider = Sdk.CreateMeterProviderBuilder()
                    .SetResourceBuilder(resourceBuilder)
                    .AddMeter(SERVICE_NAME)
                    .AddOtlpExporter(options =>
                    {
                        options.Endpoint = uri;
                        options.BatchExportProcessorOptions = new()
                        {
                            MaxExportBatchSize = 512, // nombre max d’éléments par batch
                            ScheduledDelayMilliseconds = 5000, // délai max avant envoi (5s)
                            ExporterTimeoutMilliseconds = 30000 // timeout
                        };

                    }

                    )
                    .Build();
            }
        }
        catch (Exception ex)
        {
            GD.PrintErr($"❌ An error occurred in _Ready: {ex.Message}");
            _enabled = false;
        }

    }

    public static MetricType ParseMetricType(string type)
    {
        return type.ToLowerInvariant() switch
        {
            "counter" => MetricType.Counter,
            "updowncounter" => MetricType.UpDownCounter,
            "histogram" => MetricType.Histogram,
            "gauge" => MetricType.ObservableGauge,
            "observablecounter" => MetricType.ObservableCounter,
            "observableupdowncounter" => MetricType.ObservableUpDownCounter,
            _ => throw new ArgumentException($"Invalid metric type: {type}")
        };
    }
    public static void CreateMetric(string name, string type, string unit = null, string description = null,
    Func<Measurement<long>> longCallback = null, Func<Measurement<double>> doubleCallback = null)
    {
        if (DynamicMetrics.ContainsKey(name))
            return;

        var metricType = ParseMetricType(type);

        object metric = metricType switch
        {
            MetricType.Counter => Meter.CreateCounter<long>(name, unit ?? "", description ?? ""),
            MetricType.UpDownCounter => Meter.CreateUpDownCounter<long>(name, unit ?? "", description ?? ""),
            MetricType.Histogram => Meter.CreateHistogram<double>(name, unit ?? "", description ?? ""),
            MetricType.ObservableGauge => Meter.CreateObservableGauge(name, doubleCallback ?? (() => new Measurement<double>(0))),
            MetricType.ObservableCounter => Meter.CreateObservableCounter(name, longCallback ?? (() => new Measurement<long>(0))),
            MetricType.ObservableUpDownCounter => Meter.CreateObservableUpDownCounter(name, longCallback ?? (() => new Measurement<long>(0))),
            _ => throw new ArgumentOutOfRangeException(nameof(type), type, null)
        };

        DynamicMetrics[name] = metric;
    }
    public static void AddToMetric(string name, long value, params KeyValuePair<string, object>[] tags)
    {
        if (DynamicMetrics.TryGetValue(name, out var metric) && metric is Counter<long> counter)
            counter.Add(value, tags);
        else if (metric is UpDownCounter<long> upDownCounter)
            upDownCounter.Add(value, tags);
        else
            GD.PrintErr($"Metric '{name}' not found or is not a counter.");
    }

    public static void RecordToHistogram(string name, double value, params KeyValuePair<string, object>[] tags)
    {
        if (DynamicMetrics.TryGetValue(name, out var metric) && metric is Histogram<double> histogram)
            histogram.Record(value, tags);
        else
            GD.PrintErr($"Metric '{name}' not found or is not a histogram.");
    }

    public static void GDS_CreateMetric(string name, string type)
    {
        CreateMetric(name, type);
    }

    public static void GDS_AddToMetric(string name, long value, Godot.Collections.Dictionary tags = null)
    {
        var kvTags = tags != null
            ? ConvertTags(tags)
            : Array.Empty<KeyValuePair<string, object>>();

        AddToMetric(name, value, kvTags);
    }

    public static void GDS_RecordHistogram(string name, double value, Godot.Collections.Dictionary tags = null)
    {
        var kvTags = tags != null
            ? ConvertTags(tags)
            : Array.Empty<KeyValuePair<string, object>>();

        RecordToHistogram(name, value, kvTags);
    }

    private static KeyValuePair<string, object>[] ConvertTags(Godot.Collections.Dictionary tags)
    {
        var list = new List<KeyValuePair<string, object>>();
        foreach (var key in tags.Keys)
        {
            list.Add(new KeyValuePair<string, object>(key.ToString(), tags[key]));
        }
        return list.ToArray();
    }

    public static string GDS_StartActivity(string name, Godot.Collections.Dictionary tags = null)
    {
        var activity = ActivitySource.StartActivity(name, ActivityKind.Internal);
        if (activity == null) return string.Empty;

        if (tags != null)
        {
            foreach (var key in tags.Keys)
            {
                activity.SetTag(key.ToString(), tags[key]);
            }
        }

        var id = Guid.NewGuid().ToString();
        ActiveActivities[id] = activity;
        return id;
    }

    public static void GDS_StopActivity(string id)
    {
        if (ActiveActivities.TryGetValue(id, out var activity))
        {
            activity.Stop();
            ActiveActivities.Remove(id);
        }
    }
    public static void GDS_AddTagsToActivity(string id, Godot.Collections.Dictionary tags)
    {
        if (ActiveActivities.TryGetValue(id, out var activity))
        {
            foreach (var key in tags.Keys)
            {
                activity.SetTag(key.ToString(), tags[key]);
            }
        }
    }


    public static void LogWithLevel(LogLevelType level, string section, string message, Godot.Collections.Dictionary tags = null, Exception ex = null)
    {
        if (level < CurrentLevel)
            return; // filtrage
        List<KeyValuePair<string, object>> kvTags = new();

        foreach (var key in tags.Keys)
        {
            kvTags.Add(new KeyValuePair<string, object>(key.ToString(), tags[key]));
        }
        // Ajouter la section comme tag
        kvTags.Add(new KeyValuePair<string, object>("section", section));

        // Ajout du scope pour OpenTelemetry
        using (_logger!.BeginScope(kvTags))
        {
            // Log sans section dans le message
            switch (level)
            {
                case LogLevelType.Trace: _logger.LogTrace(ex, message); break;
                case LogLevelType.Debug: _logger.LogDebug(ex, message); break;
                case LogLevelType.Information: _logger.LogInformation(ex, message); break;
                case LogLevelType.Warning: _logger.LogWarning(ex, message); break;
                case LogLevelType.Error: _logger.LogError(ex, message); break;
                case LogLevelType.Critical: _logger.LogCritical(ex, message); break;
            }
        }
    }

    public static int GDS_GetLogLevelType()
    {
        return (int)CurrentLevel;
    }
    public static void GDS_Log(string level, string section, string message, Godot.Collections.Dictionary tags = null)
    {
        if (!Enum.TryParse<LogLevelType>(level, true, out var parsedLevel))
            parsedLevel = LogLevelType.Information;

        LogWithLevel(parsedLevel, section, message, tags);
    }

    public static void GDS_LogTrace(string section, string message, Godot.Collections.Dictionary tags = null) => LogWithLevel(LogLevelType.Trace, section, message, tags);

    public static void GDS_LogDebug(string section, string message, Godot.Collections.Dictionary tags = null) => LogWithLevel(LogLevelType.Debug, section, message, tags);

    public static void GDS_LogInformation(string section, string message, Godot.Collections.Dictionary tags = null) => LogWithLevel(LogLevelType.Information, section, message, tags);

    public static void GDS_LogWarning(string section, string message, Godot.Collections.Dictionary tags = null) => LogWithLevel(LogLevelType.Warning, section, message, tags);

    public static void GDS_LogError(string section, string message, Godot.Collections.Dictionary tags = null) => LogWithLevel(LogLevelType.Error, section, message, tags);

    public static void GDS_LogCritical(string section, string message, Godot.Collections.Dictionary tags = null) => LogWithLevel(LogLevelType.Critical, section, message, tags);

    public override void _ExitTree()
    {
        // Cleanup
        _loggerFactory?.Dispose();
        ActivitySource.Dispose();
        Meter.Dispose();
    }

}


