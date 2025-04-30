# 📋 PREREQUISITES for SBOM Generation

This document outlines the necessary tools and steps to prepare your environment for generating Software Bill of Materials (SBOM) using Tern and related utilities.

---

## 🛠️ Tools Required

The following tools must be installed on the system:

- [Tern](https://github.com/tern-tools/tern) – Main tool for SBOM generation.
- [skopeo](https://github.com/containers/skopeo) – Required by Tern to pull and inspect container images.
- [jq](https://stedolan.github.io/jq/) – For processing JSON.
- [cyclonedx-cli](https://github.com/CycloneDX/cyclonedx-cli) – To work with CycloneDX SBOMs.
- `uuid-runtime` – For generating UUIDs.
- `getfattr` – For attribute fetching on files.
- `pip`, `pipx`, `python3` – For managing Python dependencies.

---

## ⚙️ Auto Installation Logic

When executing the setup script, it:

- Checks for the existence of the tools above.
- Installs any missing utilities.
- Skips installation for tools already available.
- Displays a summary of all tool statuses with versions.

---

## ✅ Sample Output

```
🔹 Checking python3... ✅ FOUND - Version: Python 3.12.3  
🔹 Checking pip3... ✅ FOUND - Version: pip 24.0 from /usr/lib/python3/dist-packages/pip (python 3.12)  
🔹 Checking pipx... ✅ FOUND - Version: 1.4.3  
🔹 Checking jq... ✅ FOUND - Version: jq-1.7  
🔹 Checking skopeo... ✅ FOUND - Version: skopeo version 1.13.3  
🔹 Checking getfattr... ✅ FOUND - Version: getfattr 2.5.2  
🔹 Checking cyclonedx... ✅ FOUND - Version: 0.27.2+f934c99826339cb8dbb83b439eb2c465fb253fb3

Installing tern script to /var/lib/jenkins/.tern-venv/bin  
🔹 Checking tern... ✅ FOUND - Version: Tern at commit 717ea47be7310d055b86fb1b80d39fb472c0ddbf  
🔹 python version = 3.12.3 (main, Feb  4 2025, 14:48:35)  

✅ All utilities and Tern installed successfully!
```

---

## 📎 Additional Notes

- Ensure `pipx` is in your system `PATH` after installation.
- You may run the script as a Jenkins step or locally on any Linux host with sufficient privileges.
- To **clone the Git repository** (e.g., `cpp-sbom`) and **commit the generated SBOM** under the `~/sbom-reports` folder from within a Jenkins job:
  - Add `GITHUB_TOKEN` as a **"Secret text"** credential in the Jenkins **Job > Configure > Build Environment** section.
  - Also add the token under **Jenkins > Manage Jenkins > Credentials**.
  - Use the HTTPS format for Git operations:
    https://${GITHUB_TOKEN}@github.com/<your-username>/<repo-name>.git

---

## ✅ Access for Private Docker Images

If you are scanning **private Docker images**, authentication must be configured to allow `skopeo` and `tern` to pull images.

### Steps:

1. Create the Docker `config.json` file with encoded credentials in jenkins machine:

```bash
echo -n 'your-username:your-password' | base64
```

2. Use the base64 output in the following format:

```json
{
  "auths": {
    "https://index.docker.io/v1/": {
      "auth": "<base64-encoded-credentials>"
    }
  }
}
```

3. Save this file to:

```bash
/var/lib/jenkins/.docker/config.json
```

4. Set proper permissions:

```bash
sudo chown jenkins:jenkins /var/lib/jenkins/.docker/config.json
chmod 600 /var/lib/jenkins/.docker/config.json
```

5. Export the path in the Jenkins job script - Make sure to add this export statement before running: "tern report -----" command:

```bash
export REGISTRY_AUTH_FILE=/var/lib/jenkins/.docker/config.json
```

---

This ensures that private Docker images can be scanned and SBOMs can be generated and submitted to SSD successfully.

---

## 📂 References

- [Tern Documentation](https://github.com/tern-tools/tern)
- [CycloneDX CLI Usage](https://github.com/CycloneDX/cyclonedx-cli)

---

© OpsMx | SBOM Automation
