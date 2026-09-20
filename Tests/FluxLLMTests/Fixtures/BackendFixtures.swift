import Foundation

/// Reduced, synthetic wire fixtures. Values are chosen for deterministic tests;
/// field names/semantics were checked against upstream documentation on 2026-09-22.
/// They are intentionally literal (not generated from the production parsers).
///
/// vLLM V1: https://docs.vllm.ai/en/latest/design/metrics/#metrics-publishing-prometheus
/// Rapid-MLX: routes/health.py at https://github.com/raullenchai/Rapid-MLX
///   /v1/status uses num_running for activity; generation_tps may persist after completion.
/// llama.cpp: tools/server/server-task.cpp and server-context.cpp at
///   https://github.com/ggml-org/llama.cpp (predicted_tokens_seconds is a server average).
enum BackendFixtures {
    static let vllmFirst = """
        # TYPE vllm:generation_tokens_total counter
        vllm:generation_tokens_total{model_name="model-a",engine="0"} 100
        vllm:generation_tokens_total{model_name="model-a",engine="1"} 200
        vllm:generation_tokens_total{model_name="model-b",engine="0"} 300
        vllm:prompt_tokens_total{model_name="model-a",engine="0"} 20
        vllm:prompt_tokens_total{model_name="model-a",engine="1"} 30
        vllm:prompt_tokens_total{model_name="model-b",engine="0"} 40
        vllm:num_requests_running{model_name="model-a",engine="0"} 1
        vllm:num_requests_running{model_name="model-a",engine="1"} 2
        vllm:num_requests_running{model_name="model-b",engine="0"} 1
        vllm:num_requests_waiting{model_name="model-a",engine="0"} 2
        vllm:request_generation_tokens_bucket{model_name="model-a",le="+Inf"} 99999
        """

    static let vllmSecond = """
        vllm:generation_tokens_total{engine="1",model_name="model-a"} 240
        vllm:generation_tokens_total{engine="0",model_name="model-a"} 120
        vllm:generation_tokens_total{engine="0",model_name="model-b"} 320
        vllm:num_requests_running{model_name="model-a",engine="0"} 1
        vllm:num_requests_running{model_name="model-a",engine="1"} 2
        vllm:num_requests_running{model_name="model-b",engine="0"} 1
        """

    static let rapidActive =
        #"{"status":"generating","model":"mlx-community/Qwen3","uptime_s":50,"num_running":2,"num_waiting":1,"total_completion_tokens":150,"total_prompt_tokens":400,"generation_tps":75.5,"prompt_tps":201.1,"metal":{"active_memory_gb":8,"peak_memory_gb":9,"cache_memory_gb":2},"requests":[]}"#
    static let rapidIdle =
        #"{"status":"idle","model":"mlx-community/Qwen3","uptime_s":52,"num_running":0,"num_waiting":0,"total_completion_tokens":300,"total_prompt_tokens":400,"generation_tps":75.5,"requests":[]}"#
    static let llamaActive = """
        llamacpp:tokens_predicted_total 1000
        llamacpp:tokens_predicted_seconds_total 40
        llamacpp:prompt_tokens_total 2000
        llamacpp:predicted_tokens_seconds 25.5
        llamacpp:requests_processing 2
        llamacpp:requests_deferred 1
        """
    static let llamaProps =
        #"{"default_generation_settings":{"n_ctx":4096},"total_slots":2,"model_alias":"local-model","endpoint_metrics":false,"is_sleeping":false}"#
}
