"""CLI for the installed ITL facade adapter; no direct 1C launch or backend HTTP."""
import argparse
import json
import os
from itl_remote.vanessa import command, daemon

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("prepare", "feature", "cleanup", "daemon"))
    parser.add_argument("feature", nargs="?")
    args = parser.parse_args()
    if args.operation != "cleanup" and not args.feature:
        parser.error("feature is required")
    if args.operation == "daemon":
        daemon(os.environ["ITL_RUN_CONTEXT"], args.feature)
    else:
        print(json.dumps(command(args.operation, args.feature), ensure_ascii=True))
