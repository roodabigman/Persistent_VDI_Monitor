# program opening text, details, version, etc
Write-Host "###############################################################################################################"
Write-Host "Welciome to the Persistent Desktop Usage Montor tool. this script seaches for all assigned machines in a site"
Write-Host "and gathers all sessions & connections to that machine within the search timeframe specified.  each machine"
Write-Host "gets a last-use timestamp and an aggregate usage time within the search period specified. These API"
Write-Host "queries are READ-ONLY, so you cannot make any changes / interrupt a production environment using this program."
Write-Host "Version 1.0, 05/05/2023"
Write-Host "Written by BVB"
Write-Host "###############################################################################################################"

# Function to retrieve Bearer Token using API credentials
function GetBearerToken {

    param (
        [Parameter(Mandatory=$true)]
        [string] $clientId,
        [Parameter(Mandatory=$true)]
        [string] $clientSecret
    )
        $body = @{
            grant_type = "client_credentials"
            client_id = $clientId
            client_secret =$clientSecret }
        $trustUrl = " https://api-us.cloud.com/cctrustoauth2/root/tokens/clients "
        $response = Invoke-WebRequest $trustUrl -Method POST -Body $body -SkipHttpErrorCheck
        
        # write HTTP response status code to console - if failed, provide status code and break execution
        if (200..299 -contains $response.StatusCode) {
            Write-Host 'API token Accepted, downloading bearer token'
        }
        else {
            Write-Host '*********FAILED TO RETRIEVE BEARER TOKEN************'
            Write-Host "Response code: $($response.StatusCode)"
            Write-Host 'please check your customer id, client id, and client secret, and try again'
            Read-Host 'Press Enter to Exit'
            exit
        }

    return $response;
}

# function to query Monitor API, call this function each time you need to send a new GET request, provide request URL, auth token, and customer details
function query_workspace_api($queryurl, $bearertoken, $customername) {
    $query_headers = @{
        'Authorization' = $bearertoken
        'Citrix-CustomerId' = $customername
    }
    $payload = @{}
    $retries = 4
    while ($retries -gt 0) {
        $response = Invoke-WebRequest -Uri $queryurl -Headers $query_headers -Method Get -Body $payload
        if (-not (200..299 -contains $response.StatusCode)) {
            Write-Host "API Query failed with error:"
            Write-Host "Response code: $($response.StatusCode)"
            Start-Sleep -Seconds 2
            $retries -= 1
            continue
        }
        return $response.content | ConvertFrom-Json
    }
    Write-Host "ERROR: Orchestration API did not return data with 4 retries, check status codes returned"
    return @{ }
}

# Set environment details
# ****************************** ENTER YOUR CUSTOMER DETAILS HERE ******************************
$customer_name = ""
$client_id = ""
$client_secret = ""

# set bearer token and expiration variables
$bearerToken = ""
$bearerExpiration = 0

# set search parameter variables
# ****************************** ENTER DESIRED SEARCH PERIOD HERE ******************************
$lookbackdays = 7
$querystart = (Get-Date).Date.AddDays(-$lookbackdays)
$querystart_str = $querystart.ToString("yyyy-MM-dd")

#set Odata pagination variables
$continue_marker = 1
$skipcount = 0

# define array to hold PSCustomObjects generated by loop
$usagetable = @()

while ($continue_marker -gt 0) {

    if ((Get-Date) -gt $bearerExpiration) {
        # call function to retrieve and store bearer tokenin JSON response
        $bearer_response = GetBearerToken $client_id $client_secret

        # extract the token from the JSON response and prepend required syntax for Citrix APIs
        $bearerToken = "CwsAuth Bearer=$(($bearer_response.content | ConvertFrom-Json).access_token)"

        # set expiration time of token, for large dataset collection it may be necessary to refresh the bearer token during execution
        $bearerExpiration = (Get-Date).AddSeconds(($bearer_response.content | ConvertFrom-Json).expires_in - 120)
    }
    else {
        $query_url = 'https://api-us.cloud.com/monitorodata/Machines?&
                                $filter=IsAssigned eq true&
                                $select=DnsName,AssociatedUserUPNs&
                                $expand=Sessions($select=StartDate,EndDate;
                                $filter=EndDate ge {0} or EndDate eq null;
                                $expand=Connections($select=EstablishmentDate,DisconnectDate;
                                $filter=DisconnectDate ge {0} or DisconnectDate eq null))
                                &$skip={1}' -f $querystart_str, $skipcount
                                #  and DnsName eq ''<machine.example.com''

        $starttime = Get-Date # start timer to track API call timing
        $api_response = query_workspace_api $query_url $bearerToken $customer_name
        $endtime = Get-Date # end timer to track API call timing
        $elapsedTime = $endTime - $startTime # total time taken to get API response
        Write-Host "Monitor API call Elapsed time: $($elapsedTime.TotalSeconds) seconds, current skip count is: $($skipcount)"
        $firsttry = $api_response.value

        # iterate through each machine / user pair in the data returned from the Monitor API
        foreach ($item in $firsttry) {
            # reset the usage time each time we iterate the loop, as we are looking at a new user
            $usagetime = New-Timespan

                # check if the given machine has sessions in the search timeframe, if not, apply a "not used" value to the last usage
                if ($null -ne $item.Sessions -and $item.Sessions.Length -gt 0) {
                    
                    # assign an index to use for the most recent session. this is necessary as failed sessions show up in the data with matching start and end times and will contain a connection shown with null entries, need to 
                    # iterate to the first "real" session and look at the connection data
                    $index = 0
                    $sortedsession = ($item.Sessions | Sort-Object StartDate -Descending)
                    while ($null -ne $sortedsession[$index].EndDate -and (New-Timespan -End $sortedsession[$index].EndDate -Start $sortedsession[$index].StartDate) -lt (New-Timespan -Minutes 1)) {
                            # getting here means our sorted sessions have a bad session on top, iterate the index to look at the next one down, 
                            # continue until real session is found. this can index out of bounds of sessions, which will make the $null test fail and exit the loop
                            # essentially that means there are no real sessions for the machines                                               
                            $index++
                    }

                    # assign last use variable for this machine - if the most recent connection has no end date, it means the connection is active - assign the last use tag as currently in use. otherwise grab the time stamp
                    if ($item.Sessions.Connections.Count -eq 0 -or ($null -eq ($item.Sessions.Connections.EstablishmentDate | Measure-Object -Maximum).Maximum)) {
                        $lastuse = 'not used'
                    }
                    else {
                        $lastDisconnect = ($item.Sessions | Sort-Object StartDate -Descending)[$index].Connections | Sort-Object EstablishmentDate -Descending | Select-Object -First 1                
                        if ($null -eq $lastDisconnect.DisconnectDate) {
                            $lastuse = 'currently in use'
                        }
                        else {
                            $lastuse = $lastDisconnect.DisconnectDate
                        }
                    }

                    # iterate through sessions and connections to determine usage time
                    foreach ($session in $item.Sessions) {
                        $connections = $session.Connections
                        foreach ($connection in $connections) {
                            if ($null -ne $connection.EstablishmentDate) {
                                $start = if ($connection.EstablishmentDate -lt $querystart) { $querystart } else { $connection.EstablishmentDate }
                    
                                #if disconnect date is null, could mean there is an active session, but could also be bad data where the end date just didnt get recorded... 
                                #in this case want to check if the connection entry is actually the most recent in the sessions table, and establishment date is within the search period, 
                                #will work in 99% of cases to groom out bad data, might end up using bad data for a connection in the other 1%...
                                if ($null -eq $connection.DisconnectDate) {
                                    #check if establishment date of this connection is the most recent connection associated with the session
                                    if ($connection.EstablishmentDate -eq ($connections.EstablishmentDate | Measure-Object -Maximum).Maximum) {
                                        # check if session has an end date - that would mean the lack of end date for the connection is bad data
                                        $end = if ($null -ne $session.EndDate) { $session.EndDate } else { Get-Date -AsUTC }
                                    }
                                    else {
                                        # set end time to match start date so the connection evaluation is preserved but the duration of connection will be 0
                                        $end = $start
                                    }
                                }
                                else {
                                    $end = $connection.DisconnectDate
                                }
                                $usagetime = $usagetime.Add((New-TimeSpan -Start $start -End $end))

                                # Write-Host $start
                                # Write-Host $end
                                # Write-Host (New-TimeSpan -Start $start -End $end)
                            }
                        }
                    }                            
                }
                else {
                    # getting here means there are no sessions recorded in the search timeframe for the given machine, i.e. it has not been used, write 'not used' as last timestamp
                    $lastuse = 'not used'
                }
            # create PSCustomObject table with the relevent details
            $machineusage = [PSCustomObject]@{
                User = $item.AssociatedUserUPNs
                Machine = $item.DnsName
                Last_Used = $lastuse
                Total_Usage_Hours = $usagetime.TotalHours
            }
            # add PSCustomObject table of machine usage to the usage array
            $usagetable += $machineusage
        }
        # check if further API calls are necessary to collect all data
        if (($api_response | Get-Member -MemberType NoteProperty).Count -gt 2) {
            $skipcount += 100
        }
        else {
            $continue_marker = 0
        }
    }
}

# ****************************** ENTER YOUR DESIRED OUTPUT PATH HERE ******************************
$usagetable | Export-Csv -Path /Users/username/projects/persistent_desktop_usage.csv  

# home for lunch