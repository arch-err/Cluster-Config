from __future__ import annotations

import logging

import uvicorn

from .api import create_app
from .config import Config


def run() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    uvicorn.run(
        create_app(Config.from_env()),
        host="0.0.0.0",
        port=8080,
        access_log=False,
        proxy_headers=True,
        forwarded_allow_ips="*",
    )
