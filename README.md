# PSE-Action

This GitHub Action provides detailed analysis of all the network transactions done by the action. The action uses transparent HTTPS proxy using iptables. The iptables rules are set up by the action.

## Restrictions
- Only works with Alpine container builds.
- Build container must allow root access to run iptables.
- Build container should be provided net_admin capability.

## Output
The output is set as checks associated with the build. These checks can be summarized using OpenAI ChatBot.

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
      # Run PSE as service
      pse:
        image: public.ecr.aws/i1j1q8l2/pse-public:latest
        env:
           GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }} # should have permissions to write checks
           OPENAI_AUTH_TOKEN: ${{ secrets.OPENAI_AUTH_TOKEN }} # if set, use OpenAI chat to summarize
           
    container:
      image: node:19-alpine
      options: --cap-add=NET_ADMIN
      
    runs-on: ubuntu-latest
    
    steps:
     # setup PSE action
      - uses: invisirisk-demo/pse-action@v2
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
      - uses: actions/checkout@v3
      - run: make
```

