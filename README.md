# Pipeline Security Engine

In recent years, there have been several high-profile security breaches that have exploited vulnerabilities in build pipelines. These breaches have exposed sensitive data, such as:

- Data exfiltration
- Code injection
- Denial of service (DoS) attacks
- Supply chain attacks
- Intellectual Property


Recent pipeline compromises like 3CX, Kaseya, CircleCI, SolarWinds, CodeCov, and others have highlighted the need for securing the build pipeline.

Pipeline Security Engine  provides detailed analysis and control of all the network transactions done by software builds. PSE deployments can be used to protect against such threats.


## Design
The PSE action sets up iptables rules to redirect all port 443 traffic to service container named PSE. The PSE container runs an SSL inspection proxy analyzing traffic flowing between your build and rest of the world. The PSE Action sets up CA certificate from the proxy service as a trusted certificate in your build container providing seamless service.

## Features
### Full Network Traffic Visibility
PSE scans all traffic from your build containers, providing full detailed view and control.

### Policy Control
Full policy control over what should be admitted to the build system. PSE uses [Rego](https://www.openpolicyagent.org/docs/latest/policy-language/) as the policy language.

The policy control allows for alert or block of traffic.

Here are examples of action runs:
- [Basic NPM Demo](https://github.com/invisirisk/pse-action/actions/runs/4840230332/jobs/8625753277)
- [Secret Leak Demo](https://github.com/invisirisk/pse-action/actions/runs/4840230332/jobs/8625756297)
- [Block by Policy Demo](https://github.com/invisirisk/pse-action/actions/runs/4840230332/jobs/8625751936)

#### Example block report

> ##### :no_entry_sign: git - pull - github.com/TheTorProject/gettorbrowser
> ##### OpenAI Summary
> The activity of trying to pull code from the GitHub repository for gettorbrowser was blocked due to policy. There is no related risk from the build system.
>
> ##### Details
> Blocked: Blocked by policy


### Secret Scan
PSE scans all outgoing traffic for secrets. These requests can be blocked or can raise alert based on configuration.

#### Example Report
> ##### :warning: web - post - risky.com/
>
> ##### Details
> - URL: https://risky.com/post-target
> - GitHub-App-Token: secret value ghs_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXg,
> - Download-Type: mime: text/html; charset=utf-8
> - Download-Checksum: checksum 5dc1213c14995bdf78755c41174b0060

## Input
Service Container Environments
 - GITHUB_TOKEN: Required. Github token with permission to write checks
 - OPENAI_AUTH_TOKEN: Optional. If provided, call out to OpenAI to summarize activities.
 - POLICY_URL: URL from where to fetch policy
 - POLICY_AUTH_TOKEN: Bearer token used to authenticate with policy provider
 - POLICY_LOG: if set enable policy log
 


Action Input
 - github-token: Required. Github token

## Usage
To use this action, add the following step to your workflow:

```
name: CI-Build

on:
  push:
  pull_request:

permissions:
  checks: write
  contents: read
  
jobs:
  build:

    services:
      # Run PSE as service -> Service must be named PSE.
      pse:
        image: invisirisk/pse
        env:
           GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }} # should have permissions to write checks
           OPENAI_AUTH_TOKEN: ${{ secrets.OPENAI_AUTH_TOKEN }} # if set, use OpenAI chat to summarize
           
           POLICY_URL: https://api.github.com/repos/invisirisk/policy/tarball/main #if set the URL to pull policy bundle from
           POLICY_AUTH_TOKEN: ${{ secrets.POLICY_AUTH_TOKEN }} # bearer auth token used when pull down policy
           POLICY_LOG: t # if set enables policy logging
           
           PSE_DEBUG_FLAG: --alsologtostderr # enable PSE logging
           
    container:
      image: node:19-alpine
      options: --cap-add=NET_ADMIN
      
    runs-on: ubuntu-latest
    
    steps:
     # setup PSE action
      - uses: invisirisk/pse-action@v1
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
      - uses: actions/checkout@v3
      - run: make
```


## Policy Interface
PSE uses rego for policies. The PSE will fetch policy as a tarball from POLICY_URL. Policy auth can be set using POLICY_AUTH_TOKEN token.

Here is example policy for controlling access to git:
```
package git

import future.keywords.in

# generate alert
alert(repo, act) = output {
	item := [repo, act]

	output := sprintf("accessing repo %s with action %s", item)
}

# allow all access from invisirisk-demo
read_allow {
	glob.match("github.com/invisirisk-demo/**", [], input.details.repo)
	input.action in ["pull"]
}

# warn if build tries to access anything else

decision = {"result": "allow"} {
	read_allow
} else := {"result": "alert/warn", "details": alert(input.details.repo, input.action)}

```

### Policy return
Policy return should include the following details:
- result: allow, deny, alert/warn, alert/error, alert/crit
- details: if result is alert, message associated with the alert

#### Example alert report

> ##### :warning: git - pull - github.com/TheTorProject/gettorbrowser
> ###### OpenAI Summary
> The activity involved accessing the Github repository for the Tor Browser and pulling content. The related risk could be the potential for the introduction of malicious code into the build system.
> ###### Details
> - Alert: accessing repo github.com/TheTorProject/gettorbrowser with action pull
> - Download-Type: mime: text/plain; charset=utf-8
> - Download-Checksum: checksum cddb06e275ca09d516bc759f77ac5efe 
#### Example block report

> ###### :no_entry_sign: git - pull - github.com/TheTorProject/gettorbrowser
> ###### OpenAI Summary
> The activity of trying to pull code from the GitHub repository for gettorbrowser was blocked due to policy. There is no related risk from the build system.
>
> ###### Details
> Blocked: Blocked by policy



## Output
The output is set as checks associated with the build. These checks can be summarized using OpenAI ChatBot.
Here is an [example Output Report](https://github.com/invisirisk/pse-action/actions/runs/4840230332/jobs/8625753277)


### Roadmap
- [X] Basic proxy for Alpine Container
- [X] Provide output as Github Check
- [X] Check of secrets in all POSTs
- [X] go module
- [X] npm module
- [X] git operations
- [X] web operations
- [ ] MVN operations
- [ ] PyPI support
- [X] Ubuntu, Debian Container
- [X] Policy Interface
## Restrictions
- Only works with Alpine, Debian, and Ubuntu container builds.
- Build container must allow root access to run iptables.
- Build container should be provided net_admin capability.

### Licensing
The project is licensed under [Apache License v2](https://www.apache.org/licenses/LICENSE-2.0).

