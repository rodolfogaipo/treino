#!/bin/bash
# Monta o APK Android do TREINO+ (roda sozinho no GitHub Actions).
set -e
RUN=${GITHUB_RUN_NUMBER:-1}
OWNER=$(echo "${GITHUB_REPOSITORY%%/*}" | tr '[:upper:]' '[:lower:]')
NAME="${GITHUB_REPOSITORY##*/}"
if [ "$(echo "$NAME" | tr '[:upper:]' '[:lower:]')" = "$OWNER.github.io" ]; then SITE="https://$OWNER.github.io/"; else SITE="https://$OWNER.github.io/$NAME/"; fi
echo "Site: $SITE"

mkdir app && cd app
npm init -y > /dev/null
npm i @capacitor/core@7.6.9 @capacitor/cli@7.6.9 @capacitor/android@7.6.9 @capacitor/share@7.0.4 @capacitor/filesystem@7.1.9
mkdir www
cp -r ../site/. www/
rm -rf www/.git www/.github www/apk
test -f www/index.html || { echo "index.html nao encontrado na raiz do repositorio"; exit 1; }
sed -i "s#<head>#<head><meta name=\"site-url\" content=\"$SITE\">#" www/index.html
cat > capacitor.config.json <<'JSON'
{
  "appId": "com.treinoplus.app",
  "appName": "TREINO+",
  "webDir": "www",
  "backgroundColor": "#0D0D0D",
  "android": { "adjustMarginsForEdgeToEdge": "force" }
}
JSON
npx cap add android
npx cap sync android
RES=android/app/src/main/res

# Icone do app
rm -rf $RES/mipmap-anydpi-v26
for d in $RES/mipmap-*; do
  cp www/icons/icon-512.png $d/ic_launcher.png
  cp www/icons/icon-512.png $d/ic_launcher_round.png
  rm -f $d/ic_launcher_foreground.png
done

# Tela de abertura escura com o logo
command -v convert > /dev/null || sudo apt-get install -y -qq imagemagick > /dev/null
LOGO=www/icons/splash-logo.png; [ -f $LOGO ] || LOGO=www/icons/icon-512.png
for f in $(find $RES -name splash.png); do
  S=$(identify -format '%wx%h' "$f")
  convert -size "$S" xc:'#0D0D0D' \( $LOGO -resize 320x320 \) -gravity center -composite "$f"
done

# Barras do sistema escuras
sed -i 's#<item name="android:background">@null</item>#<item name="android:background">@null</item><item name="android:statusBarColor">\#0D0D0D</item><item name="android:navigationBarColor">\#0D0D0D</item><item name="android:windowLightStatusBar">false</item>#' $RES/values/styles.xml

# Versao do app
sed -i "s/versionCode 1/versionCode $RUN/; s/versionName \"1.0\"/versionName \"1.$RUN\"/" android/app/build.gradle

# Compilar e assinar
cd android
chmod +x gradlew
./gradlew assembleRelease --no-daemon -q
BT=$(ls -d $ANDROID_HOME/build-tools/* | sort -V | tail -1)
$BT/zipalign -f 4 app/build/outputs/apk/release/app-release-unsigned.apk aligned.apk
$BT/apksigner sign --ks ../../site/apk/chave.keystore --ks-pass pass:treinoplus --key-pass pass:treinoplus --ks-key-alias treino --out ../../TREINO-plus.apk aligned.apk
ls -la ../../TREINO-plus.apk
