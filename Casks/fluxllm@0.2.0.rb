cask "fluxllm@0.2.0" do
  version "0.2.0"
  sha256 "f1d13d16ada0df904b6f5df041766ec868a770c58610f29c2fd4495d8b06e0e7"

  url "https://github.com/chmorgan/fluxllm/releases/download/0.2.0/FluxLLM-0.2.0.zip"
  name "FluxLLM"
  desc "Menu bar monitor and proxy for local language models"
  homepage "https://github.com/chmorgan/fluxllm"

  livecheck do
    skip "This cask installs a fixed release"
  end

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "FluxLLM.app"

  caveats <<~EOS
    Install only one FluxLLM cask at a time. Uninstall the current cask before switching versions.
  EOS
end
