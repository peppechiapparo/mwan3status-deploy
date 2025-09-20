#: GRIMALDI deploy notes

This short note documents the runtime version handling used by the `updateMwan3StatusPage.sh`
deploy script and how to override the version value at deploy time.

Version canonicalization
-------------------------
The deploy script generates a machine-readable file on the device at `/www/mwan3/version.json`.
This JSON file is the canonical runtime metadata that monitoring tools and clients should use.

How the version is chosen
-------------------------
- By default the script uses the hard-coded `WEBAPP_VERSION` variable inside the script (currently `1.1`).
- You can override the value at deploy-time by setting the environment variable
  `WEBAPP_VERSION_OVERRIDE` when invoking the script. The override will be written into
  `/www/mwan3/version.json` and reflected in the injected HTML comment `<!-- webapp-version: ... -->`.

Examples
--------
# Run locally and use the script default version:
/bin/sh /opt/updateMwan3StatusPage.sh

# Force a specific version value (useful from CI or manual deploy):
WEBAPP_VERSION_OVERRIDE="2.0" /bin/sh /opt/updateMwan3StatusPage.sh

CI note
-------
If you run deploys from CI, prefer to set `WEBAPP_VERSION_OVERRIDE` from your pipeline configuration
or release job so `version.json` reflects the released version. This avoids committing version
files into the repository and keeps the device runtime metadata deterministic.

Testing the result
------------------
- Confirm `/www/mwan3/version.json` contains the expected `version` field.
- Open `/www/mwan3/index.html` and verify the first line contains the `<!-- webapp-version: X -->`
  comment matching the version in `version.json`.

Permissions
-----------
The deploy script writes under `/www/mwan3/` and `/www/cgi-bin/`. Ensure the user running the script
has the necessary filesystem permissions on the target device (the deploy task typically copies the
script to `/opt` then runs it via SSH as root or an account with write access to `/www`).
