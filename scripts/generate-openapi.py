"""Generate the committed v1 OpenAPI contract without starting a server."""

import json
import os
import secrets
from pathlib import Path

from devpulse_core.api import create_app


def main() -> None:
    os.environ["DEVPULSE_DATA_DIR"] = str(Path.cwd() / ".tmp" / "openapi-data")
    app = create_app(access_token=secrets.token_urlsafe(32), refresh_on_start=False)
    destination = Path("services/local-core/openapi/v1.json")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("w", encoding="utf-8", newline="\n") as contract:
        contract.write(json.dumps(app.openapi(), indent=2) + "\n")


if __name__ == "__main__":
    main()
