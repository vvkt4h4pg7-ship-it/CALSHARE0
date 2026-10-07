@echo off
setlocal
cd /d "%~dp0"

if "%~1"=="" (
  set "REMOTE=https://github.com/vvkt4h4pg7-ship-it/CALSHARE0.git"
  echo Varsayilan GitHub: %REMOTE%
) else (
  set "REMOTE=%~1"
)

echo [1/5] Git kontrol...
git --version >nul 2>&1 || (
  echo Git bulunamadi.
  exit /b 1
)

if not exist .git (
  echo [2/5] Yeni Git repository olusturuluyor...
  git init
  git branch -M main
) else (
  echo [2/5] Mevcut Git repository kullaniliyor...
)

git remote get-url origin >nul 2>&1
if errorlevel 1 (
  git remote add origin "%REMOTE%"
) else (
  git remote set-url origin "%REMOTE%"
)

echo [3/5] Dosyalar ekleniyor...
git add .

if errorlevel 1 (
  echo git add basarisiz.
  exit /b 1
)

echo [4/5] Commit...
git diff --cached --quiet
if errorlevel 1 (
  git commit -m "CALLSHARE iOS R0 - clean BLE CallKit audio architecture"
) else (
  echo Commit icin yeni degisiklik yok.
)

echo [5/5] GitHub'a push...
git push -u origin main

if errorlevel 1 (
  echo.
  echo PUSH BASARISIZ.
  echo GitHub repo'nun URL'sini ve giris/yetkilendirme durumunu kontrol et.
  exit /b 1
)

echo.
echo ==========================================
echo CALLSHARE iOS R0 PUSH TAMAMLANDI
 echo ==========================================
echo.
endlocal
