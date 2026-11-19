#!/bin/bash
# Monta o projeto Android a partir dos arquivos soltos e gera o APK assinado.
set -e
mkdir -p www assets
cp index.html www/index.html
cp icon-only.png icon-foreground.png icon-background.png splash.png splash-dark.png assets/
npx cap add android
cp atelas-release.jks android/app/atelas-release.jks
cp keystore.properties android/keystore.properties
pip install --quiet pillow
python3 - <<'PY'
import os
from PIL import Image
# assinatura fixa e versão
p='android/app/build.gradle'
t=open(p).read()
t=t.replace("apply plugin: 'com.android.application'\n","""apply plugin: 'com.android.application'

def keystoreProps = new Properties()
def keystoreFile = rootProject.file('keystore.properties')
if (keystoreFile.exists()) { keystoreProps.load(new FileInputStream(keystoreFile)) }
""",1)
t=t.replace("    buildTypes {\n        release {","""    signingConfigs {
        release {
            if (keystoreFile.exists()) {
                storeFile file(keystoreProps['storeFile'])
                storePassword keystoreProps['storePassword']
                keyAlias keystoreProps['keyAlias']
                keyPassword keystoreProps['keyPassword']
            }
        }
    }
    buildTypes {
        release {
            signingConfig signingConfigs.release""",1)
t=t.replace('versionCode 1\n        versionName "1.0"','versionCode 16\n        versionName "1.0.0"')
open(p,'w').write(t)
# ícone de notificação (branco sobre transparente)
f=Image.open('assets/icon-foreground.png').convert('RGBA')
f=f.crop(f.split()[3].point(lambda v:255 if v>40 else 0).getbbox())
for d,s in [('mdpi',24),('hdpi',36),('xhdpi',48),('xxhdpi',72),('xxxhdpi',96)]:
    d2='android/app/src/main/res/drawable-%s'%d;os.makedirs(d2,exist_ok=True)
    h=int(s*0.9);w=max(1,int(f.width*h/f.height))
    c=Image.new('RGBA',(s,s),(0,0,0,0));c.alpha_composite(f.resize((w,h),Image.LANCZOS),((s-w)//2,(s-h)//2))
    c.save(d2+'/ic_stat_icon.png')
PY
# ---- widgets da tela inicial e microfone (código nativo Android)
bash widgets.sh

npx capacitor-assets generate --android
npx cap sync android
chmod +x android/gradlew
./android/gradlew -p android assembleRelease
