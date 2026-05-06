# Security Notes

This repository is intended to be safe to publish as source code. It should not contain:

- `OPENAI_API_KEY` values
- wallet files
- agent state files
- private keys or GPG exports
- logs from a real miner
- personal KYA handles or personal agent addresses

Before publishing, run:

```bash
bash tests/public-image-release.sh
```
