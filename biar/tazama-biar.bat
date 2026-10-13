@echo off
setlocal enabledelayedexpansion

cd /d "%~dp0"

:menu
cls
echo.
echo ============================================================
echo  Tazama BIAR Launcher
echo ============================================================
echo.
echo  Pre-requisite: tazama-core must be running on Server A
call :nifi_auth_status
echo.
echo    1. Deploy BIAR stack (DockerHub images)
echo    2. Deploy BIAR stack (GitHub builds)
echo    3. Utilities / teardown
echo.
set /p "choice=Select option (1-3), or (q)uit: "

if /i "%choice%"=="q" goto :quit
if /i "%choice%"==""   goto :menu
if "%choice%"=="1"     goto :check_core_hub
if "%choice%"=="2"     goto :check_core_dev
if "%choice%"=="3"     goto :utils
goto :menu

:: ---------------------------------------------------------------
:: Pre-flight: verify tazama-core is reachable
:: ---------------------------------------------------------------
:check_core_hub
set "DEPLOY_TARGET=hub"
goto :check_core
:check_core_dev
set "DEPLOY_TARGET=dev"
goto :check_core
:check_core
:: Read SERVER_A_HOST from .env (default: localhost for single-machine; set to private IP for AWS multi-host)
set "SERVER_A_HOST=localhost"
for /f "usebackq tokens=1,* delims==" %%A in (".env") do (
    if /i "%%A"=="SERVER_A_HOST" set "SERVER_A_HOST=%%B"
)
:: Verify core is reachable via NATS exterior port (14222)
powershell -NoProfile -Command "try { $t = New-Object Net.Sockets.TcpClient('!SERVER_A_HOST!', 14222); $t.Close(); exit 0 } catch { exit 1 }" >nul 2>&1
if errorlevel 1 (
    echo.
    echo  ERROR: tazama-core is not reachable at !SERVER_A_HOST!:14222
    echo         Ensure tazama-core is running and SERVER_A_HOST is set correctly in .env
    echo.
    pause
    goto :menu
)
goto :deploy

:: ---------------------------------------------------------------
:: Deploy
:: ---------------------------------------------------------------
:deploy
if "%DEPLOY_TARGET%"=="hub" goto :deploy_hub
goto :deploy_dev

:deploy_hub
echo.
echo  Deploying BIAR stack (DockerHub images)...
echo.
docker compose -p tazama-biar ^
    -f ./docker-compose.biar.infrastructure.yaml ^
    -f ./docker-compose.hub.biar.yaml ^
    -f ./docker-compose.utils.init.yaml ^
    up -d
goto :done

:deploy_dev
echo.
echo  Deploying BIAR stack (GitHub builds)...
echo.
docker compose -p tazama-biar ^
    -f ./docker-compose.biar.infrastructure.yaml ^
    -f ./docker-compose.dev.biar.yaml ^
    -f ./docker-compose.utils.init.yaml ^
    up -d
goto :done

:: ---------------------------------------------------------------
:: Utilities
:: ---------------------------------------------------------------
:utils
cls
echo.
echo  Utilities:
echo    1. Tear down BIAR
echo    b. Back
echo.
set /p "util=Select option: "
if /i "%util%"=="b"  goto :menu
if "%util%"=="1"     goto :down_biar
goto :utils

:down_biar
docker compose -p tazama-biar ^
    -f ./docker-compose.biar.infrastructure.yaml ^
    -f ./docker-compose.hub.biar.yaml ^
    -f ./docker-compose.dev.biar.yaml ^
    -f ./docker-compose.utils.init.yaml ^
    down --volumes
goto :done

:done
echo.
echo  Done.
pause
goto :menu

:: ---------------------------------------------------------------
:: Show which NiFi authentication mode (NIFI_AUTH in .env) the next deploy uses
:: ---------------------------------------------------------------
:nifi_auth_status
set "NIFI_AUTH_SHOW=none"
set "NIFI_PORT_SHOW=8088"
set "NIFI_HTTPS_PORT_SHOW=8443"
set "NIFI_BIND_SHOW=127.0.0.1"
for /f "usebackq tokens=1,* delims==" %%A in (".env") do (
    if /i "%%A"=="NIFI_AUTH" set "NIFI_AUTH_SHOW=%%B"
    if /i "%%A"=="NIFI_PORT" set "NIFI_PORT_SHOW=%%B"
    if /i "%%A"=="NIFI_HTTPS_PORT" set "NIFI_HTTPS_PORT_SHOW=%%B"
    if /i "%%A"=="NIFI_BIND_ADDRESS" set "NIFI_BIND_SHOW=%%B"
)
if "!NIFI_AUTH_SHOW!"=="" set "NIFI_AUTH_SHOW=none"
if "!NIFI_PORT_SHOW!"=="" set "NIFI_PORT_SHOW=8088"
if "!NIFI_HTTPS_PORT_SHOW!"=="" set "NIFI_HTTPS_PORT_SHOW=8443"
if "!NIFI_BIND_SHOW!"=="" set "NIFI_BIND_SHOW=127.0.0.1"
if /i "!NIFI_AUTH_SHOW!"=="none" (
    if "!NIFI_BIND_SHOW!"=="127.0.0.1" (
        echo  NiFi auth: none  ^(http://localhost:!NIFI_PORT_SHOW!/nifi, this machine only^)
    ) else (
        echo  NiFi auth: none  ^(http://localhost:!NIFI_PORT_SHOW!/nifi, NO LOGIN, open on !NIFI_BIND_SHOW!^)
    )
    exit /b 0
)
if /i "!NIFI_AUTH_SHOW!"=="keycloak" (
    echo  NiFi auth: keycloak  ^(https://localhost:!NIFI_HTTPS_PORT_SHOW!/nifi, needs core Authentication^)
    exit /b 0
)
echo  NiFi auth: !NIFI_AUTH_SHOW!  (unsupported; set NIFI_AUTH to none or keycloak in .env)
exit /b 0

:quit
endlocal
exit /b 0
