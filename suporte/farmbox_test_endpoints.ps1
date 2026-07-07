# Farmbox API - Teste completo de endpoints (porta PowerShell do .py)
# Salva cada resposta em JSON em ./farmbox_responses/

$ErrorActionPreference = 'Stop'

# --- Configuracao ---
$TOKEN   = 'Hlr3mHzEfGSTiwt1v5aFIA'
$BASE    = 'https://farmbox.cc/api/v1'
$OUT_DIR = Join-Path $PSScriptRoot 'farmbox_responses'
# --------------------

$AUTH_HEADERS_TO_TRY = @(
    @{ name = 'Authorization'; value = "Token $TOKEN" }
    @{ name = 'Authorization'; value = "Bearer $TOKEN" }
    @{ name = 'X-Api-Token';   value = $TOKEN }
    @{ name = 'X-Auth-Token';  value = $TOKEN }
    @{ name = 'Api-Token';     value = $TOKEN }
)

$ENDPOINTS = @(
    @('farms',                     '/farms')
    @('plots',                     '/plots')
    @('varieties',                 '/varieties')
    @('plantations',               '/plantations')
    @('plantations_state_filter',  '/plantations?state=active')
    @('applications',              '/applications')
    @('application_progresses',    '/application_progresses')
    @('inputs',                    '/inputs')
    @('resource_subscriptions',    '/resource_subscriptions')
    @('harvests',                  '/harvests')
    @('cropped_volumes',           '/cropped_volumes')
    @('batches',                   '/batches')
    @('storages',                  '/storages')
    @('movimentations',            '/movimentations')
    @('application_movimentations','/application_movimentations')
    @('monitorings',               '/monitorings')
    @('monitoring_day_results',    '/monitoring_day_results')
)

New-Item -ItemType Directory -Force -Path $OUT_DIR | Out-Null

function Invoke-Fetch {
    param($Url, $HeaderName, $HeaderValue)
    $headers = @{ $HeaderName = $HeaderValue; 'Accept' = 'application/json' }
    try {
        $resp = Invoke-WebRequest -Uri $Url -Headers $headers -TimeoutSec 15 -UseBasicParsing
        return @{ status = [int]$resp.StatusCode; body = $resp.Content; err = $null }
    } catch [System.Net.WebException] {
        $r = $_.Exception.Response
        if ($r) {
            $status = [int]$r.StatusCode
            $sr = New-Object System.IO.StreamReader($r.GetResponseStream())
            $body = $sr.ReadToEnd()
            return @{ status = $status; body = $body; err = $null }
        }
        return @{ status = $null; body = $null; err = $_.Exception.Message }
    } catch {
        # Invoke-WebRequest on PS5 throws non-WebException for HTTP errors sometimes
        $resp = $_.Exception.Response
        if ($resp) {
            $status = [int]$resp.StatusCode
            try {
                $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $body = $sr.ReadToEnd()
            } catch { $body = '' }
            return @{ status = $status; body = $body; err = $null }
        }
        return @{ status = $null; body = $null; err = $_.Exception.Message }
    }
}

function Detect-Auth {
    Write-Host "`n[*] Detectando formato de autenticacao..."
    foreach ($h in $AUTH_HEADERS_TO_TRY) {
        $res = Invoke-Fetch -Url "$BASE/farms" -HeaderName $h.name -HeaderValue $h.value
        $short = $h.value.Substring(0, [Math]::Min(30, $h.value.Length))
        if ($res.err) {
            Write-Host ("  [X] {0}: {1}... -> ERRO: {2}" -f $h.name, $short, $res.err)
            continue
        }
        $mark = if ($res.status -eq 200) { 'OK ' } else { 'XX ' }
        Write-Host ("  [{0}] {1}: {2}... -> HTTP {3}" -f $mark, $h.name, $short, $res.status)
        if ($res.status -eq 200) { return $h }
    }
    return $null
}

function Test-Endpoints {
    param($Auth)
    $results = [ordered]@{}
    Write-Host ("`n[*] Testando {0} endpoints...`n" -f $ENDPOINTS.Count)

    $farm_id = $null; $plantation_id = $null; $monitoring_id = $null

    foreach ($ep in $ENDPOINTS) {
        $name = $ep[0]; $path = $ep[1]
        $url = "$BASE$path"
        Write-Host ("  GET {0,-45}" -f $path) -NoNewline

        $res = Invoke-Fetch -Url $url -HeaderName $Auth.name -HeaderValue $Auth.value
        if ($res.err) {
            Write-Host ("ERRO: {0}" -f $res.err)
            $results[$name] = @{ error = $res.err; url = $url }
            continue
        }

        $data = $null
        if ($res.body) {
            try { $data = $res.body | ConvertFrom-Json } catch { $data = @{ raw = $res.body.Substring(0,[Math]::Min(500,$res.body.Length)) } }
        }

        $count = $null
        if ($data -is [System.Array]) { $count = $data.Count }
        elseif ($data -and $data.PSObject.Properties.Name -contains 'data' -and $data.data -is [System.Array]) { $count = $data.data.Count }

        $countStr = if ($null -ne $count) { " ($count registros)" } else { '' }
        Write-Host ("HTTP {0}{1}" -f $res.status, $countStr)

        $results[$name] = @{ status = $res.status; url = $url; data = $data }

        if ($name -eq 'farms' -and $data -is [System.Array] -and $data.Count) { $farm_id = $data[0].id }
        if ($name -eq 'plantations' -and $data -is [System.Array] -and $data.Count) { $plantation_id = $data[0].id }
        if ($name -eq 'monitorings' -and $data -is [System.Array] -and $data.Count) { $monitoring_id = $data[0].id }

        Start-Sleep -Milliseconds 300
    }

    $id_tests = @()
    if ($farm_id) {
        $id_tests += ,@('farms_by_id',          "/farms/$farm_id")
        $id_tests += ,@('pluviometer_coverage',  "/farms/$farm_id/pluviometer_coverage")
    }
    if ($monitoring_id) {
        $id_tests += ,@('monitorings_by_id',     "/monitorings/$monitoring_id")
    }

    if ($id_tests.Count) { Write-Host "`n  -- Testes com IDs reais --" }
    foreach ($t in $id_tests) {
        $name = $t[0]; $path = $t[1]
        $url = "$BASE$path"
        Write-Host ("  GET {0,-45}" -f $path) -NoNewline
        $res = Invoke-Fetch -Url $url -HeaderName $Auth.name -HeaderValue $Auth.value
        if ($res.err) { Write-Host $res.err; $results[$name] = @{ error = $res.err }; continue }
        $data = $null
        if ($res.body) { try { $data = $res.body | ConvertFrom-Json } catch { $data = @{ raw = $res.body.Substring(0,[Math]::Min(500,$res.body.Length)) } } }
        Write-Host ("HTTP {0}" -f $res.status)
        $results[$name] = @{ status = $res.status; url = $url; data = $data }
        Start-Sleep -Milliseconds 300
    }

    return $results
}

function Save-Results {
    param($Results, $Auth)
    $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss')
    $summary_path = Join-Path $OUT_DIR "_summary_$ts.json"
    $full_path    = Join-Path $OUT_DIR "_full_$ts.json"

    $full = [ordered]@{
        generated_at = (Get-Date).ToUniversalTime().ToString('o')
        auth_header  = $Auth.name
        base_url     = $BASE
        results      = $Results
    }
    $full | ConvertTo-Json -Depth 30 | Out-File -FilePath $full_path -Encoding utf8

    $summary = [ordered]@{}
    foreach ($name in $Results.Keys) {
        $res = $Results[$name]
        if ($res.ContainsKey('error')) {
            $summary[$name] = @{ error = $res.error }
        } else {
            $data = $res.data
            $count = '?'
            $first = $null
            if ($data -is [System.Array]) {
                $count = $data.Count
                if ($data.Count -and $data[0] -is [PSCustomObject]) { $first = $data[0].PSObject.Properties.Name }
            } elseif ($data -and $data.PSObject.Properties.Name -contains 'data' -and $data.data -is [System.Array]) {
                $count = $data.data.Count
            }
            $summary[$name] = @{ status = $res.status; url = $res.url; count = $count; fields = $first }
        }
    }
    $summary | ConvertTo-Json -Depth 10 | Out-File -FilePath $summary_path -Encoding utf8

    foreach ($name in $Results.Keys) {
        $ep_path = Join-Path $OUT_DIR "$name.json"
        $Results[$name].data | ConvertTo-Json -Depth 30 | Out-File -FilePath $ep_path -Encoding utf8
    }

    Write-Host "`n[OK] Respostas salvas em: $OUT_DIR"
    Write-Host "   Resumo:   $summary_path"
    Write-Host "   Completo: $full_path"
}

# --- main ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host ('=' * 60)
Write-Host '  Farmbox API - Teste de Endpoints'
Write-Host "  Base URL : $BASE"
Write-Host ("  Token    : {0}***" -f $TOKEN.Substring(0,8))
Write-Host ('=' * 60)

$auth = Detect-Auth
if (-not $auth) {
    Write-Host "`n[X] Nenhum formato de autenticacao funcionou. Verifique o token."
    exit 1
}
Write-Host ("`n[OK] Auth confirmado: {0}: {1}" -f $auth.name, $auth.value)

$results = Test-Endpoints -Auth $auth
Save-Results -Results $results -Auth $auth

$ok  = ($results.Values | Where-Object { $_.status -eq 200 }).Count
$err = ($results.Values | Where-Object { $_.status -ne 200 -or $_.ContainsKey('error') }).Count
Write-Host "`n--- Sumario ---"
Write-Host ("  OK: {0} endpoints  |  Erro: {1}" -f $ok, $err)
