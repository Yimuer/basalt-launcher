using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace BasaltLauncher3;

/// <summary>Where the engine lives and how to talk to it. Mirrors the PowerShell launcher's conventions.</summary>
public sealed class BasaltPaths
{
    public string Root { get; }
    public string Endpoint { get; }
      public string? PidFile { get; }
    public string StartCmd => Path.Combine(Root, "start.cmd");
    public string StopCmd => Path.Combine(Root, "stop.cmd");
    public string WebUrl => Endpoint + "/";

      public BasaltPaths(string root, string endpoint, string? pidFile)
      {
          Root = root;
          Endpoint = endpoint;
          PidFile = string.IsNullOrWhiteSpace(pidFile) ? null : pidFile;
      }

    /// <summary>Reads set KEY=VALUE from config.cmd, tolerating the quoted form set "KEY=VALUE".</summary>
    private static string? CfgValue(string text, string key)
    {
        Match m = Regex.Match(text, "(?im)^\\s*set\\s+\"?" + key + "\\s*=\\s*\"?([^\"\\r\\n]+)\"?");
        return m.Success ? m.Groups[1].Value.Trim() : null;
    }

    /// <summary>
    /// Expands cmd-style %NAME% references the way config.cmd expects them: BASALT_ROOT
    /// resolves to the detected root, other names fall back to the process environment.
    /// Mirrors the PowerShell launcher's expander (up to four passes).
    /// </summary>
    private static string ExpandCmdVars(string value, string root)
    {
        for (int pass = 0; pass < 4; pass++)
        {
            string next = Regex.Replace(value, "%([A-Za-z_][A-Za-z0-9_]*)%", m =>
            {
                string name = m.Groups[1].Value.ToUpperInvariant();
                if (name == "BASALT_ROOT") { return root; }
                string? env = Environment.GetEnvironmentVariable(name);
                return string.IsNullOrEmpty(env) ? m.Value : env!;
            });
            if (next == value) { break; }
            value = next;
        }
        return value;
    }

    public static BasaltPaths Detect()
    {
        string root = Environment.GetEnvironmentVariable("BASALT_ROOT") ?? "";
        if (root.Length == 0 || !Directory.Exists(root))
        {
            root = @"C:\Program Files\basalt";
            if (!Directory.Exists(root))
            {
                // Fall back to walking up from the executable (dev tree layout).
                DirectoryInfo? dir = new(AppContext.BaseDirectory);
                while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "start.cmd")))
                {
                    dir = dir.Parent;
                }
                if (dir is not null) { root = dir.FullName; }
            }
        }

        int port = 8080;
        string host = "127.0.0.1";
          string? pidFile = null;
        string config = Path.Combine(root, "bin", "config.cmd");
        if (File.Exists(config))
        {
            try
            {
                string text = File.ReadAllText(config);
                  string? portText = CfgValue(text, "PORT");
                  if (portText is not null && int.TryParse(portText, out int parsedPort) && parsedPort > 0) { port = parsedPort; }
                  string? hostText = CfgValue(text, "HOST") ?? CfgValue(text, "SVC_HOST");
                  if (!string.IsNullOrEmpty(hostText) && !hostText!.Contains('%')) { host = hostText!; }
                  pidFile = CfgValue(text, "PIDFILE");
                  if (pidFile is not null) { pidFile = ExpandCmdVars(pidFile, root); }
            }
            catch (Exception) { /* keep defaults */ }
        }

          return new BasaltPaths(root, "http://" + host + ":" + port, pidFile);
    }
}

/// <summary>One rendered read of the engine. Everything is nullable because /metrics can lag /health.</summary>
public sealed record EngineSnapshot(
    bool Reachable,
    string Key,
    string Text,
    string? Model,
    string? Version,
    int? Percent,
    int? MaxContext,
    double? TokS,
    int? GpuUtil,
    long? MemUsed,
    long? MemTotal,
    int? Temp,
    double? Cpu,
    long? Requests,
    string? Error);

public sealed class EngineClient : IDisposable
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(2.5) };
    private readonly string _endpoint;

    public EngineClient(string endpoint) { _endpoint = endpoint; }

    public async Task<EngineSnapshot> ProbeAsync(CancellationToken ct)
    {
        JsonDocument? health = await GetJsonAsync(_endpoint + "/health", ct).ConfigureAwait(false);
        if (health is null)
        {
            return new EngineSnapshot(false, "down", "未响应", null, null, null, null, null, null, null, null, null, null, null,
                "无法连接 " + _endpoint);
        }

        bool loaded = Bool(health, "loaded");
        bool loading = Bool(health, "loading");
        int? percent = Int(health, "percent");
        string? model = Str(health, "model");
        int? ctx = Int(health, "max_context");

        JsonDocument? metrics = await GetJsonAsync(_endpoint + "/metrics", ct).ConfigureAwait(false);

        string? version = null;
        string? liveState = null;
        double? tokS = null;
        int? gpuUtil = null, temp = null;
        long? memUsed = null, memTotal = null;
        double? cpu = null;
        long? requests = null;

        if (metrics is not null)
        {
            version = StrIn(metrics, "engine", "version");
            liveState = StrIn(metrics, "live", "state");
            tokS = DblIn(metrics, "live", "tok_s");
            if (tokS is null) { tokS = DblPath(metrics, "best", "decode", "tok_s"); }
            cpu = DblPath(metrics, "hardware", "cpu");
            requests = LngPath(metrics, "totals", "requests");

            if (metrics.RootElement.TryGetProperty("hardware", out JsonElement hw) &&
                hw.TryGetProperty("gpus", out JsonElement gpus) &&
                gpus.ValueKind == JsonValueKind.Array && gpus.GetArrayLength() > 0)
            {
                JsonElement g = gpus[0];
                gpuUtil = Int(g, "util");
                temp = Int(g, "temp");
                memUsed = Lng(g, "mem_used");
                memTotal = Lng(g, "mem_total");
            }
        }

        string key, text;
        if (loading) { key = "loading"; text = percent is null ? "正在加载模型" : "正在加载模型 " + percent + "%"; }
          else if (loaded && liveState is not null && liveState != "idle") { key = "busy"; text = "运行中（" + StateZh(liveState) + "）"; }
        else if (loaded) { key = "ok"; text = "运行中（空闲）"; }
        else { key = "stopped"; text = "已加载=否（服务未就绪）"; }

        return new EngineSnapshot(true, key, text, model, version, percent, ctx, tokS, gpuUtil,
            memUsed, memTotal, temp, cpu, requests, null);
    }

    /// <summary>Chinese label for engine live states; unknown states pass through instead of being guessed.</summary>
    private static string StateZh(string state) => state switch
    {
        "generating" => "生成中",
        "decoding" => "解码中",
        "prefill" => "预处理中",
        "processing" => "处理中",
        "loading" => "加载中",
        "paused" => "已暂停",
        "sleeping" => "休眠",
        _ => state,
    };

    private static async Task<JsonDocument?> GetJsonAsync(string url, CancellationToken ct)


    {
        try
        {
            using var resp = await Http.GetAsync(url, ct).ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode) { return null; }
            string body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            return JsonDocument.Parse(body);
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static bool Bool(JsonDocument d, string p) => d.RootElement.TryGetProperty(p, out JsonElement e) && e.ValueKind == JsonValueKind.True;
    private static string? Str(JsonDocument d, string p) => d.RootElement.TryGetProperty(p, out JsonElement e) && e.ValueKind == JsonValueKind.String ? e.GetString() : null;
    private static int? Int(JsonElement e, string p) => e.TryGetProperty(p, out JsonElement v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : (int?)null;
    private static int? Int(JsonDocument d, string p) => Int(d.RootElement, p);
    private static long? Lng(JsonElement e, string p) => e.TryGetProperty(p, out JsonElement v) && v.ValueKind == JsonValueKind.Number ? v.GetInt64() : (long?)null;
    private static long? LngPath(JsonDocument d, params string[] path)
    {
        JsonElement cur = d.RootElement;
        foreach (string p in path)
        {
            if (!cur.TryGetProperty(p, out JsonElement next)) { return null; }
            cur = next;
        }
        return cur.ValueKind == JsonValueKind.Number ? cur.GetInt64() : (long?)null;
    }
    private static double? DblIn(JsonDocument d, string group, string prop)
        => d.RootElement.TryGetProperty(group, out JsonElement g) && g.TryGetProperty(prop, out JsonElement v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : (double?)null;
    private static double? DblPath(JsonDocument d, params string[] path)
    {
        JsonElement cur = d.RootElement;
        foreach (string p in path)
        {
            if (!cur.TryGetProperty(p, out JsonElement next)) { return null; }
            cur = next;
        }
        return cur.ValueKind == JsonValueKind.Number ? cur.GetDouble() : (double?)null;
    }
    private static string? StrIn(JsonDocument d, string group, string prop)
        => d.RootElement.TryGetProperty(group, out JsonElement g) && g.TryGetProperty(prop, out JsonElement v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    public void Dispose() { }
}
