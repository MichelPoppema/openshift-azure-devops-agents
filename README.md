# Description

OpenShift manifests and instructions for running Azure Agent on OpenShift

# Documentation
- Adapted from https://github.com/byroncollins/azure-devops-agent-openshift
- [running azure agent in Docker](https://docs.microsoft.com/en-us/azure/devops/pipelines/agents/docker?view=azure-devops#linux)
- based on [azure-pipelines-ephemeral-agents](https://github.com/microsoft/azure-pipelines-ephemeral-agents)

# Build Instructions

## Customisations

- Based on Centos:stream8 with findutils and (un)zip
- Automatic cleanup of agents on container exit
- ephermal agent runs a single job and then exits using --once
- Node.js & NPM (16)
- DotNet SDK 6.0
- Java 11/17 & Maven 3.8
- Python 3.9

## Create azure-repos pull secret

The build template expects a source secret available on the Openshift namespace called *azdogitsshkey*. This SSH key should be registered under an account with access to the repository. In Openshift, use *Create source secret* and add the private key.

## Create imagestream

Openshift expects an imagestream called Centos:stream8 as basis to build the agent based on these templates
This can be added to your imagestream with:  
```oc import-image centos:stream8 --confirm```

# Azure Agent Deployment

The included build script for Azure DevOps expects three variables to be defined:
* AZP_POOL : The Agent pool in which the agents are going to run
* AZP_URL : The URL to the Azure DevOps organisation (cloud) or collection (on-premise)
* AZP_TOKEN : A PAT token with sufficient permissions. This is only the **Agent Pools** > **Read & Manage** permission

## Scale agents

By default, the build will deploy two pods. However, by explicitly overriding the value REPLICAS in the deploymentconfig (for 4, add ```-p REPLICAS=4``` to the *Process deployment template* step in the build-pipeline) you can deploy more.

# Deployment from Azure Pipelines

You can now execute Azure Pipeline jobs using your azure-agent running in the OpenShift Cluster

## Openshift Service Connection

Connection to Openshift is done through a Service Connection in Azure DevOps, named: OpenshiftServiceConnection
You should create a service account on Openshift in the correct namespace (my-namespace) and use the token for authentication.

## OpenShift Documentation

 - [Service Accounts](https://docs.openshift.com/container-platform/4.7/authentication/understanding-and-creating-service-accounts.html)

## Create project and service account

The service account could exist in the same project that you've created to run the azure agents

```bash
oc create serviceaccount azure-agent -n my-namespace
```

## Assign project admin role to namespaces

```bash
oc policy add-role-to-user admin -z azure-agent -n my-namespace
```

## Retreve token

Tokens are generated automatically when the service account is created and are created as secrets   

Delete the secrets to automatically regenerate

```bash
oc describe sa/azure-devops-agent
Name:                azure-agent
Namespace:           azure-agent
Labels:              <none>
Annotations:         <none>
Image pull secrets:  azure-agent-dockercfg-28g22
Mountable secrets:   azure-agent-token-cp46z
                     azure-agent-dockercfg-28g22
Tokens:              azure-agent-token-cp46z
                     azure-agent-token-f5hzv
Events:              <none>
```

```bash 
oc get secrets azure-agent-token-f5hzv
```

The value of the token should be used in the *OpenshiftServiceConnection*

## Proxy for agent
If you need to connect your agent to an Azure DevOps instance outside the intranet through a proxy, this needs to be passed along to the configuration of the agent. Check Byron Collins repository for an example: https://github.com/byroncollins/azure-devops-agent-openshift
