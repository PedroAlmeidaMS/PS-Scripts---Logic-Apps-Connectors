$subscriptioName = 'YOUR SUBSCRIPTION'
$resourceGroupName = 'YOUR RESOURCE GROUP'

## LOGIN to your Azure Account
az login
az account set --subscription $subscriptioname

$path = '/Temp/' + $Env:USER
##Do not change the Connections file name
$pathFile = $path + '/connections.json'
$csvFilepath = $path + '/OrphanedConnectorsStandard.csv'

#use the collection to build up objects for the table
$connectorDictionary = New-Object "System.Collections.Generic.Dictionary``2[System.String,System.Object]" 

##Searches for the API Connectors in the RG. Adds them to the table
##Convert to JSON when debugging, to see results. For script execution, remove the Convert, else the ForEach will not work properly.
Write-Host ''
Write-Host 'Looking up API Connectors in Resource Group' $resourceGroupName
Write-Host 'Will classify as Connected or in Error, does not mean it is used!!'
$resources = Get-AzResource -ResourceGroupName $resourcegroupName -ResourceType Microsoft.Web/connections -ExpandProperties #|  ConvertTo-Json
$resources | ForEach-Object { 
    ##Classifying Connector Type
    if($_.Kind -eq 'V1')
    {   Write-Host 'Found connector:' ($_.Properties.api.psobject.Properties | Where-Object {$_.Name -eq "displayName"}).Value '| Connector Name: '$_.Name '|  Consumption Managed Connector | Status:' $_.Properties.overallStatus '| connected user:' $_.Properties.authenticatedUser.psobject.Properties.value }
    else
    { 
        ##Adds the resource to the Dictionary
        ##Add only Standard Connectors
        Write-Host 'Found Connector:' ($_.Properties.api.psobject.Properties | Where-Object {$_.Name -eq "displayName"}).Value '| Connector Name: '$_.Name '| Standard Managed Connector | Status:' $_.Properties.overallStatus '| connected user:' $_.Properties.authenticatedUser.psobject.Properties.value 
        
        $azureConnector = New-Object -TypeName psobject
        $azureConnector | Add-Member -MemberType NoteProperty -Name 'IsUsed' -Value 'FALSE'
        $azureConnector | Add-Member -MemberType NoteProperty -Name 'Id' -Value $_.Id
        $azureConnector | Add-Member -MemberType NoteProperty -Name 'name' -Value $_.Name
        $azureConnector | Add-Member -MemberType NoteProperty -Name 'Status' -Value $_.Properties.overallStatus
        if([bool]($myObject.PSobject.Properties.name -match "Deprecated"))
        { $azureConnector | Add-Member -MemberType NoteProperty -Name 'IsDeprecated' -Value $_.Properties.Deprecated }

        $connectorDictionary.Add($_.Name, $azureConnector)  
    }
}

Write-Host ''
Write-Host 'Looking up Logic Apps Standard'
$resources = Get-AzResource -ResourceGroupName $resourcegroupName -ResourceType Microsoft.Web/sites -ExpandProperties
$resources | ForEach-Object {
    ##If kind does not contain WORKFLOWAPP, it's not a Logic App, it's only a Function App.    
    if($_.Kind.Contains('workflowapp'))
    {
        Write-Host 'Logic App' $_.Name
        ##Iterate to find Workflows
         
        Write-Host ''
        Write-Host 'Looking up Workflows'
		$workflow = Get-AzResource -ApiVersion "2022-03-01" -Name $_.Name -ResourceGroupName $resourceGroupName -ResourceType "Microsoft.Web/sites/workflows/" -ExpandProperties 
		$workflow | ForEach-Object { Write-Host $_.Name  'type' $_.Kind }    

        Write-Host ''
        Write-Host 'Checking connectors in LogicApp'
        ##Get Function App properties
        $functionapp = Get-AzFunctionApp -Name $_.Name -ResourceGroupName $resourcegroupName 

        ##Context needs to be set to access Az Storage, using ConnectionString from Function App
        $context = New-AzStorageContext -ConnectionString $functionapp.ApplicationSettings.WEBSITE_CONTENTAZUREFILECONNECTIONSTRING
        $fileshare = Get-AzStorageShare -Name $functionapp.ApplicationSettings.WEBSITE_CONTENTSHARE -Context $context
        
        write-Host 'Logic App' $_.Name 'uses the following connector/s:' 
        foreach ($fileName in $fileshare.Name)
        {
            ##We need to download the file, it does not allow us to work in memory
            Get-AzStorageFileContent -ShareName $fileName -Path '/site/wwwroot/connections.json' -Context $context -Force -Destination $path
            $json = Get-Content -Raw -Path $pathFile | Out-String | ConvertFrom-Json
            foreach($obj in $json.managedApiConnections.psobject.properties)
            { 
                write-Host $obj.Value.connection.id '| Is Deprecated?' ($obj.Value.connection.name.ToString().ToUpper() -contains 'DEPRECATED') 
                #Check if connector is in the connector dictionary
                $connectorIdLower = $obj.Value.connection.id.ToString().Replace("@{","").Replace("}","").ToLower()
				if($connectorDictionary.ContainsKey($connectorIdLower))
                {
                    #Mark connector as being used                        
                    $matchingConnector = $connectorDictionary[$connectorIdLower]
                    $matchingConnector.IsUsed = 'TRUE'
                    $connectorDictionary[$connectorIdLower] = $matchingConnector 
                }
            }
        }
    }
}

Write-Host ''
Write-Host 'Orphaned API Connectors'
$connectorDictionary.Values | ForEach-Object{
    Write-Host $_.name ': is Used?' $_.IsUsed
    if($_.IsUsed -eq 'FALSE') { Write-Host $_.name ': is an orphan | ID:' $_.Id }
} 

$connectorDictionary.Values | Export-Csv -Path $csvFilepath