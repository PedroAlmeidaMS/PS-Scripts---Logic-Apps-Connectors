$resourceGroupName = 'YOUR RESOURCE GROUP'

$path = '/home/' + $Env:USER
$csvFilepath = $path + '/OrphanedConnectorsConsumption.csv'

#Get Resource Group Info
$resourceGroup = Get-AzResourceGroup -Name $resourceGroupName
$resourceGroupPath = $resourceGroup.ResourceId
Write-Host 'Resource Group Path: '  $resourceGroupPath

#use the collection to build up objects for the table
$connectorDictionary = New-Object "System.Collections.Generic.Dictionary``2[System.String,System.Object]" 

##Searches for the API Connectors in the RG. Adds them to the table
##Convert to JSON when debugging, to see results. For script execution, remove the Convert, else the ForEach will not work properly.
Write-Host ''
Write-Host 'Looking up API Connectors'
$resourceName = ''
$resources = Get-AzResource -ResourceGroupName $resourcegroupName -ResourceType Microsoft.Web/connections -ExpandProperties
$resources | ForEach-Object {    
    if($_.Kind -eq 'V1')
    {        
        Write-Host 'Found Connector:' ($_.Properties.api.psobject.Properties | Where-Object {$_.Name -eq "displayName"}).Value '| Connector Name: '$_.Name '| Status:' $_.Properties.overallStatus '| connected user:' $_.Properties.authenticatedUser.psobject.Properties.value 
        
        $resourceIdLower = $_.id.ToLower()
        ##Add members to the dictionary
        $azureConnector = New-Object -TypeName psobject
        $azureConnector | Add-Member -MemberType NoteProperty -Name 'IsUsed' -Value 'FALSE'
        $azureConnector | Add-Member -MemberType NoteProperty -Name 'Id' -Value $_.Id
        $azureConnector | Add-Member -MemberType NoteProperty -Name 'name' -Value $_.Name
        $azureConnector | Add-Member -MemberType NoteProperty -Name 'Status' -Value $_.Properties.overallStatus
        if([bool]($myObject.PSobject.Properties.name -match "Deprecated"))
        { $azureConnector | Add-Member -MemberType NoteProperty -Name 'IsDeprecated' -Value $_.Properties.Deprecated }

        $connectorDictionary.Add($resourceIdLower, $azureConnector)  
    }
}

#Check logic apps to find orphaned connectors
Write-Host ''
Write-Host 'Looking up Consumption Logic Apps'

$resources = Get-AzResource -ResourceGroupName $resourcegroupName -ResourceType Microsoft.Logic/workflows
$resources | ForEach-Object {    

    $resourceName = $_.Name    
    $logicAppName = $resourceName
    $logicApp = Get-AzLogicApp -Name $logicAppName -ResourceGroupName $resourceGroupName        
    $logicAppUrl = $resourceGroupPath + '/providers/Microsoft.Logic/workflows/' + $logicApp.Name + '?api-version=2018-07-01-preview'
    
    #Get Logic App Content using Az REST GET
    $logicAppJson = az rest --method get --uri $logicAppUrl
    $logicAppJsonText = $logicAppJson | ConvertFrom-Json
    #Check Logic App Connectors inside the Logic App JSON
    $logicAppParameters = $logicAppJsonText.properties.parameters
    $logicAppConnections = $logicAppParameters.psobject.properties.Where({$_.name -eq '$connections'}).value
    $logicAppConnectionValue = $logicAppConnections.value
    #$logicAppConnectionValues = $logicAppConnectionValue.psobject.properties.name
    
    #Iterate through the connectors
    Write-Host 'Logic App ' $logicAppName 'uses the following connector/s:'
    $logicAppConnectionValue.psobject.properties | ForEach-Object{
        $objectName = $_
        $connection = $objectName.Value
        if($connection -ne $null)
        {
            Write-Host $connection.connectionName '| Is Deprecated?' ($connection.connectionName.ToString().ToUpper() -contains 'DEPRECATED') '| id=' $connection.connectionId
            
            #Check if connector is in the connector dictionary
            $connectorIdLower = $connection.connectionId.ToLower()
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

Write-Host ''
Write-Host 'Orphaned API Connectors'
$connectorDictionary.Values | ForEach-Object{
    Write-Host $_.name ': Is used?' $_.IsUsed
    if($_.IsUsed -eq 'FALSE') { Write-Host $_.name ': is an orphan | ID:' $_.Id }
}

$connectorDictionary.Values | Export-Csv -Path $csvFilepath