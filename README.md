# Starting With PowerShell Azure Functions

This repository contains some PowerShell Azure Functions example to build some serverless automation on an Azure Subscription.

## Environment preparation and tools needed

Inside **00_EnvironmentPreparation** folder you can find a PS1 script which deploy a couple of function apps on your subscription, and assign it a system managed identity with contributor role on the parent resource group.

To work with Azure Functions you can use the portal editor; I prefer to work via **[VS Code](https://code.visualstudio.com/)** with **Azure Tools** extension installed.

If you want to run and debug Azure Functions locally, you also have to install **[Azure Functions Core Tools](https://docs.microsoft.com/it-it/azure/javascript/tutorial-vscode-serverless-node-01)** which requires **[.Net Core 2.2 runtime](https://dotnet.microsoft.com/download/dotnet-core/2.2)**.

## Slides and videos

### DevOps Heroes 2019  - Parma
Slides: https://www.slideshare.net/MarcoObinu/automazione-serverless-con-azure-functions-e-powershell-marco-obinu-devops-heroes-2019  
Video:  https://www.youtube.com/watch?v=0ZK1SQ6zkiU&t=1s  
