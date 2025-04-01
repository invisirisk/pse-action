# PSE Security Proxy GitHub Action

This GitHub Action integrates with InvisiRisk's Pipeline Security Engine (PSE) to enhance the security of your build process.

## Overview

The PSE GitHub Action helps you secure your software supply chain by monitoring and enforcing security policies during your build process. It integrates seamlessly with your existing GitHub Actions workflows to provide:

- **Security Policy Enforcement**: Prevent the use of vulnerable dependencies
- **Build Activity Monitoring**: Track network activity during your build
- **Compliance Reporting**: Generate detailed reports for audit and compliance purposes
- **Minimal Performance Impact**: Optimized for speed and reliability

## How It Works

The PSE GitHub Action performs the following steps:

1. **Prepare Mode**: Creates a scan object in the InvisiRisk Portal and obtains ECR credentials
2. **Setup Mode**: Pulls and runs the PSE proxy container to monitor network traffic
3. **Intercept Mode**: Configures iptables rules and installs certificates for HTTPS interception

By default, the action runs in "all" mode, which performs all three steps in sequence. You can also run each mode individually for more granular control over the process.

At the end of your workflow, you need to run the same action with `cleanup: true` to:
1. Send the end signal to the InvisiRisk API
2. Display the container logs
3. Clean up the PSE container and related resources

## Usage

### Basic Example

Add the PSE GitHub Action to your workflow:

```yaml
name: Build NPM Package
on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    
    strategy:
      matrix:
        node-version: [18.x]
    steps:
    - name: Setup PSE
      id: pse-setup
      uses: kkisalaya/ir-gh-action@v0.14
      with:
        api_url: 'https://app.invisirisk.com'
        app_token: ${{ secrets.INVISIRISK_TOKEN }}
        github_token: ${{ secrets.GITHUB_TOKEN }}
        
    - name: Install system dependencies
      run: |
        sudo apt-get update
        sudo apt-get install -y curl wget git
        
    - name: Checkout the code
      uses: actions/checkout@v3
      
    - name: Use Node.js ${{ matrix.node-version }}
      uses: actions/setup-node@v3
      with:
        node-version: ${{ matrix.node-version }}
        
    - name: Install dependencies
      run: |
        npm install
        npm ci
        
    - name: Build and Test
      run: |
        npm run build --if-present
        npm test
        
    - name: Cleanup PSE
      if: always()
      uses: kkisalaya/ir-gh-action@v0.14
      with:
        cleanup: 'true'
```

The PSE proxy will be set up before your build steps and cleaned up after all steps have completed. The `if: always()` condition ensures that cleanup happens even if previous steps fail.

### Using Individual Modes

You can run each mode separately for more control over the process:

#### Prepare Mode Only

```yaml
- name: Prepare PSE
  id: pse-prepare
  uses: kkisalaya/ir-gh-action@v0.14
  with:
    api_url: 'https://app.invisirisk.com'
    app_token: ${{ secrets.INVISIRISK_TOKEN }}
    github_token: ${{ secrets.GITHUB_TOKEN }}
    mode: 'prepare'
```

This will only create a scan object in the InvisiRisk Portal and obtain ECR credentials. The outputs from this step can be used in subsequent steps.

#### Setup Mode Only

```yaml
- name: Setup PSE Container
  id: pse-setup
  uses: kkisalaya/ir-gh-action@v0.14
  with:
    api_url: 'https://app.invisirisk.com'
    app_token: ${{ secrets.INVISIRISK_TOKEN }}
    github_token: ${{ secrets.GITHUB_TOKEN }}
    scan_id: ${{ steps.pse-prepare.outputs.scan_id }}
    mode: 'setup'
```

This will pull and run the PSE proxy container using the scan ID from the prepare step.

#### Intercept Mode Only

```yaml
- name: Configure PSE Interception
  uses: kkisalaya/ir-gh-action@v0.14
  with:
    scan_id: ${{ steps.pse-prepare.outputs.scan_id }}
    proxy_ip: ${{ steps.pse-setup.outputs.proxy_ip }}
    mode: 'intercept'
```

This will configure iptables rules and install certificates for HTTPS interception using the proxy IP from the setup step.

### Scan ID Options

The `scan_id` parameter can be used in two ways:

#### Default Scan ID

If no `scan_id` is provided, a default value will be used. This is suitable for most use cases.

#### Specific Scan ID

If you want to associate the cleanup with a specific scan ID from the setup step, you can pass it:

```yaml
- name: Cleanup PSE with Specific Scan ID
  if: always()
  uses: kkisalaya/ir-gh-action@v0.14
  with:
    cleanup: 'true'
    scan_id: ${{ steps.pse-setup.outputs.scan_id }}
```

### Cleanup Options

Cleanup options include:

1. **Minimal Cleanup (Using Values from Setup)**: If you don't need to specify parameters explicitly, you can use the minimal cleanup example.

```yaml
- name: Cleanup PSE (Minimal)
  if: always()
  uses: kkisalaya/ir-gh-action@v0.14
  with:
    cleanup: 'true'
```

2. **Cleanup with Explicit Parameters**: If you need to specify parameters explicitly instead of using values from the setup step:

```yaml
- name: Cleanup PSE (Explicit Parameters)
  if: always()
  uses: kkisalaya/ir-gh-action@v0.14
  with:
    api_url: 'https://app.invisirisk.com'
    app_token: ${{ secrets.INVISIRISK_TOKEN }}
    github_token: ${{ secrets.GITHUB_TOKEN }}
    cleanup: 'true'
    scan_id: ${{ steps.pse-setup.outputs.scan_id }}
```

### With Debug Mode

If you need more detailed logging, you can enable debug mode:

```yaml
- name: Setup PSE Security Proxy
  uses: ir-gh-action@v1
  with:
    api_url: 'https://your-api-url.com'
    app_token: ${{ secrets.INVISIRISK_TOKEN }}
    github_token: ${{ secrets.GITHUB_TOKEN }}
    debug: 'true'
```

### With Different Portal URL

If your InvisiRisk Portal URL is different from your API URL, you can specify both:

```yaml
- name: Setup PSE Security Proxy
  uses: ir-gh-action@v1
  with:
    api_url: 'https://api.invisirisk.com'
    app_token: ${{ secrets.INVISIRISK_TOKEN }}
    portal_url: 'https://portal.invisirisk.com'
    github_token: ${{ secrets.GITHUB_TOKEN }}
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `api_url` | URL of the InvisiRisk API | Yes for prepare and setup modes, No for cleanup | N/A |
| `app_token` | Authentication token for the InvisiRisk API | Yes for prepare and setup modes, No for cleanup | N/A |
| `portal_url` | URL of the InvisiRisk Portal | No | Same as `api_url` |
| `github_token` | GitHub token to be passed to the PSE container for GitHub authentication | No | `${{ github.token }}` |
| `debug` | Enable debug mode for verbose logging | No | `false` |
| `test_mode` | Enable test mode to bypass API calls and container setup for testing | No | `false` |
| `cleanup` | Clean up the PSE container and related resources | No | `false` |
| `mode` | The operation mode: "prepare" only gets scan ID and ECR credentials, "setup" pulls and runs the proxy container, "intercept" configures iptables and certificates. Default is "all" which performs all operations. | No | `all` |
| `proxy_ip` | IP address of the PSE proxy container when using "intercept" mode | Required for intercept mode unless proxy_hostname is provided | `''` |
| `proxy_hostname` | Hostname of the PSE proxy container when using "intercept" mode with service containers | No | `''` |
| `scan_id` | Scan ID from the prepare step. Required for setup and intercept modes unless test_mode is true. | No | `''` |

## Outputs

| Output | Description |
|--------|-------------|
| `scan_id` | The scan ID generated or used by the action |
| `ecr_username` | ECR username for accessing the PSE container |
| `ecr_token` | ECR token for accessing the PSE container |
| `ecr_region` | ECR region for accessing the PSE container |
| `ecr_registry_id` | ECR registry ID for accessing the PSE container |
| `proxy_ip` | IP address of the PSE proxy container |

## Prerequisites

1. An active InvisiRisk account with API access
2. API token with appropriate permissions
3. GitHub Actions workflow running on Ubuntu (other Linux distributions are supported but may require additional configuration)

## Troubleshooting

### Common Issues

1. **Certificate Trust Issues**:
   - Verify that your build tools respect the standard certificate environment variables
   - Contact InvisiRisk support if certificate issues persist

2. **Network Configuration Problems**:
   - Ensure that your build environment allows outbound network connections
   - Check if there are any network restrictions in your GitHub Actions environment

3. **Docker-in-Docker Issues**:
   - If your build uses Docker, ensure that the Docker daemon is properly configured

## Support

For support, please contact InvisiRisk support at support@invisirisk.com or open an issue in this repository.

## License

This GitHub Action is licensed under the [MIT License](LICENSE).
