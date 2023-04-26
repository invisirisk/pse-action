# Pipeline Security Engine

Pipeline Security Engine  provides detailed analysis and control of all the network transactions done by software builds.



## Design
The PSE action sets up iptables rules to redirect all port 443 traffic to service container named PSE. The PSE container runs an SSL inspection proxy analyzing traffic flowing between your build and rest of the world. The PSE Action sets up CA certificate from the proxy service as a trusted certificate in your build container providing seamless service.

## Features
### Full Network Traffic Visibility
PSE scans all traffic from your build containers, providing full detailed view and control.

### Policy Control
Full policy control over what should be admitted to the build system. PSE uses [Rego](https://www.openpolicyagent.org/docs/latest/policy-language/) as the policy language.

The policy control allows for alert or block of traffic.

#### Example block report

 ##### $\color{red}{\textsf{git - pull - github.com/TheTorProject/gettorbrowser}}$
 ##### OpenAI Summary
The activity of trying to pull code from the GitHub repository for gettorbrowser was blocked due to policy. There is no related risk from the build system.

##### Details
Blocked: Blocked by policy


### Secret Scan
PSE scans all outgoing traffic for secrets. These requests can be blocked or can raise alert based on configuration.

#### Example Report
##### $\color{orange}{\textsf{web - post - risky.com/ }}$

##### Details
- URL: https://app.a.invisirisk.com/post-target
- GitHub-App-Token: secret value ghs_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXg,
- Download-Type: mime: text/html; charset=utf-8
- Download-Checksum: checksum 5dc1213c14995bdf78755c41174b0060

## Input
Service Container Environments
 - GITHUB_TOKEN: Required. Github token with permission to write checks
 - OPENAI_AUTH_TOKEN: Optional. If provided, call out to OpenAI to summarize activities.
 - POLICY_URL: URL from where to fetch policy
 - POLICY_AUTH_TOKEN: Bearer token used to authenticate with policy provider
 - POLICY_LOG: if set enable policy log
 - 


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

##### $\color{orange}{\textsf{git - pull - github.com/TheTorProject/gettorbrowser}}$
 ###### OpenAI Summary
 The activity involved accessing the Github repository for the Tor Browser and pulling content. The related risk could be the potential for the introduction of malicious code into the build system.
 ###### Details
 - Alert: accessing repo github.com/TheTorProject/gettorbrowser with action pull
 - Download-Type: mime: text/plain; charset=utf-8
 - Download-Checksum: checksum cddb06e275ca09d516bc759f77ac5efe 
#### Example block report

 ###### $\color{red}{\textsf{git - pull - github.com/TheTorProject/gettorbrowser}}$
 ###### OpenAI Summary
The activity of trying to pull code from the GitHub repository for gettorbrowser was blocked due to policy. There is no related risk from the build system.

###### Details
Blocked: Blocked by policy



## Output
The output is set as checks associated with the build. These checks can be summarized using OpenAI ChatBot.
Here is an example Output Report


### $\color{green}{\textsf{git - pull - github.com/invisirisk-demo/demo-npm}}$
 #### OpenAI Summary
 The activity involved pulling data from invisirisk-demo/demo-npm on GitHub. The data downloaded had a mime type of "application/octet-stream" and a checksum of "3db9572b0c939a6943c7785b608ef67c". There is no related risk mentioned in this summary. However, there could be potential risks such as unintentionally downloading malicious code, vulnerabilities in dependencies, or introducing compatibility issues.
 #### Details
 - Download-Type: mime: application/octet-stream
 - Download-Checksum: checksum 3db9572b0c939a6943c7785b608ef67c
 ### $\color{orange}{\textsf{git - pull - github.com/TheTorProject/gettorbrowser}}$
 #### OpenAI Summary
 The activity involved accessing the Github repository for the Tor Browser and pulling content. The related risk could be the potential for the introduction of malicious code into the build system.
 #### Details
 - Alert: accessing repo github.com/TheTorProject/gettorbrowser with action pull
 - Download-Type: mime: text/plain; charset=utf-8
 - Download-Checksum: checksum cddb06e275ca09d516bc759f77ac5efe
 ### $\color{orange}{\textsf{git - pull - github.com/TheTorProject/gettorbrowser}}$
 #### OpenAI Summary
 The activity is a Git pull action to access the repository of gettorbrowser on GitHub. The downloaded file is of the application/octet-stream type with a checksum of c40a6f588d4678ce5d9e7a14419d40fd. The related risk from the build system could be the possibility of the downloaded file being corrupted or tampered with.
 #### Details
 - Alert: accessing repo github.com/TheTorProject/gettorbrowser with action pull
 - Download-Type: mime: application/octet-stream
 - Download-Checksum: checksum c40a6f588d4678ce5d9e7a14419d40fd
 ### $\color{green}{\textsf{npm - get - color@4.2.3}}$
 #### OpenAI Summary
 The activity involved using npm to download the color package version 4.2.3, which resulted in the download of a gzip file with a specific checksum for verification. The related risk from the build system could involve potential errors or vulnerabilities in the downloaded package that could compromise the security or functionality of the system.
 #### Details
 - Repository: registry.npmjs.org
 - Download-Type: mime: application/gzip
 - Download-Checksum: checksum e3145dcd2b26316e4d3b470529587fde
 ### $\color{green}{\textsf{npm - get - color-name@1.1.4}}$
 #### OpenAI Summary
 The activity involved downloading the color-name version 1.1.4 through npm and verifying its checksum to ensure its integrity. A related risk from the build system would be the possibility of downloading a compromised or malicious package, which could cause security or stability issues in the system.
 #### Details
 - Repository: registry.npmjs.org
 - Download-Type: mime: application/gzip
 - Download-Checksum: checksum a8d4412852471526b8027af2532d0d2b
 ### $\color{green}{\textsf{npm - get - color-convert@2.0.1}}$
 #### OpenAI Summary
 The activity involved downloading the "color-convert" package version 2.0.1 using npm. The package was downloaded as a gzip file with a checksum value of 0248ebc952524207e296a622372faa1f for verification. The risk from the build system would be if the downloaded package was compromised or contained malicious code, which could potentially harm the system.
 #### Details
 - Repository: registry.npmjs.org
 - Download-Type: mime: application/gzip
 - Download-Checksum: checksum 0248ebc952524207e296a622372faa1f
 ### $\color{green}{\textsf{npm - get - simple-swizzle@0.2.2}}$
 #### OpenAI Summary
 The activity involves downloading the package "simple-swizzle" version 0.2.2 using npm. The package is downloaded in gzip format with a checksum of 40accde4e2a22a6c05b871d0da2e8359 for verification. The related risk could be a mismatch in the checksum, which could indicate a potential tampering of the package during transit.
 #### Details
 - Repository: registry.npmjs.org
 - Download-Type: mime: application/gzip
 - Download-Checksum: checksum 40accde4e2a22a6c05b871d0da2e8359
 ### $\color{green}{\textsf{npm - get - is-arrayish@0.3.2}}$
 #### OpenAI Summary
 This activity involves downloading the is-arrayish@0.3.2 package through the npm package manager. The package is downloaded in gzip format and is verified using a checksum of a9411b733475f463a53cdf8656ad0811. The related risk from the build system is the potential for the package to contain malicious code, as the package is not controlled by the user and could be compromised by a malicious actor.
 #### Details
 - Repository: registry.npmjs.org
 - Download-Type: mime: application/gzip
 - Download-Checksum: checksum a9411b733475f463a53cdf8656ad0811
 ### $\color{green}{\textsf{npm - get - colorjs@0.1.9}}$
 #### OpenAI Summary
 The activity involves downloading the colorjs library version 0.1.9 using npm. The download type is gzip and the download checksum is 63acc5b5c45b136f2377f0c927fa5cfc. The related risk could be that the downloaded package could contain malicious code or vulnerabilities that could be exploited.
 #### Details
 - Repository: registry.npmjs.org
 - Download-Type: mime: application/gzip
 - Download-Checksum: checksum 63acc5b5c45b136f2377f0c927fa5cfc
 ### $\color{green}{\textsf{npm - get - color-string@1.9.1}}$
 #### OpenAI Summary
 The activity is downloading the color-string package version 1.9.1 using npm. The download is in the gzip format, and the checksum value is verified to be 0ca6a6c76fa119f0b80d60a9ab286db4. A related risk could be if the checksum value was incorrect or if the package had been compromised, which could lead to security vulnerabilities or break the functioning of the build system.
 #### Details
 - Repository: registry.npmjs.org
 - Download-Type: mime: application/gzip
 - Download-Checksum: checksum 0ca6a6c76fa119f0b80d60a9ab286db4
 ### $\color{green}{\textsf{npm - get - @invisirisk/ir-dep-npm@1.0.5}}$
 #### OpenAI Summary
 The activity involved downloading a specific npm package called "@invisirisk/ir-dep-npm" version 1.0.5. The downloaded content was identified as text/html, and the checksum was verified to match an expected value. The related risk from the build system would be any potential vulnerabilities or malware present within the downloaded package.
 #### Details
 - Repository: npm.pkg.github.com
 - Download-Type: mime: text/html; charset=utf-8
 - Download-Checksum: checksum d3f48c12112e0045bebb105f34bbe90a
 ### $\color{green}{\textsf{web - GET - drive.google.com}}$
 #### OpenAI Summary
 The activity involves sending a GET request to drive.google.com and receiving a mime type of text/plain along with a checksum of d41d8cd98f00b204e9800998ecf8427e. The related risk of this activity is potentially downloading a file that has been tampered with or corrupted during the build process. It's crucial to perform regular integrity checks on downloaded files to ensure they haven't been modified or corrupted.
 #### Details
 - URL: https://drive.google.com/uc?export=download&id=1tzTSWJ54w2IjpUjCSnGQqj8ZXhblWEwe
 - Download-Type: mime: text/plain
 - Download-Checksum: checksum d41d8cd98f00b204e9800998ecf8427e
 ### $\color{green}{\textsf{web - GET - doc-04-6k-docs.googleusercontent.com}}$
 #### OpenAI Summary
 The activity involved accessing a binary file from doc-04-6k-docs.googleusercontent.com. The file was identified as a machine binary application, and its checksum was verified as b3bdceb133d47b7c32cfbdec319a81dd. The related risk from build system could be the potential for the binary file to contain malware or be corrupted, which could harm the system or compromise sensitive data.
 #### Details
 - URL: https://doc-04-6k-docs.googleusercontent.com/docs/securesc/ha0ro937gcuc7l7deffksulhg5h7mbp1/81gvr0usdnruqmaj7plk3djn4q3ikrct/1681842825000/16468198457265399954/*/1tzTSWJ54w2IjpUjCSnGQqj8ZXhblWEwe?e=download&uuid=8ff6be92-f0bb-45b6-a4fa-5e58a3f53686
 - Download-Type: mime: application/x-mach-binary
 - Download-Checksum: checksum b3bdceb133d47b7c32cfbdec319a81dd
 
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

