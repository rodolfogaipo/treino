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
npm i @capacitor/core@7.6.9 @capacitor/cli@7.6.9 @capacitor/android@7.6.9 @capacitor/share@7.0.4 @capacitor/filesystem@7.1.9 @capacitor/local-notifications@7.0.7 @capacitor-community/background-geolocation@1.2.26
mkdir www
cp -r ../site/. www/
rm -rf www/.git www/.github www/apk
test -f www/index.html || { echo "index.html nao encontrado na raiz do repositorio"; exit 1; }
# Arquivos .gz viram nomes repetidos no Android (ex.: por.traineddata e por.traineddata.gz) — tira os .gz
find www -name '*.gz' -print -delete
sed -i "s#<head>#<head><meta name=\"site-url\" content=\"$SITE\">#" www/index.html
# Sons dos alarmes vão para dentro do app (o app só mostra a escolha de som se eles estiverem lá)
if ls www/sounds/*.wav > /dev/null 2>&1; then sed -i 's#<head>#<head><meta name="native-sounds" content="1">#' www/index.html; fi
cat > capacitor.config.json <<'JSON'
{
  "appId": "com.treinoplus.app",
  "appName": "TREINO+",
  "webDir": "www",
  "backgroundColor": "#0D0D0D",
  "android": { "adjustMarginsForEdgeToEdge": "force" },
  "plugins": { "LocalNotifications": { "smallIcon": "ic_stat_treino", "iconColor": "#00E676" } }
}
JSON
# GPS: quando não há rastreador ligado, a notificação "gravando percurso" sempre some
GEO=node_modules/@capacitor-community/background-geolocation/android/src/main/java/com/equimaps/capacitor_background_geolocation/BackgroundGeolocationService.java
if [ -f $GEO ]; then
  perl -0pi -e 's/(                    return;\n                \}\n            \}\n)(        \}\n\n        void onPermissionsGranted)/$1            if (getNotification() == null) {\n                stopForeground(true);\n            }\n$2/' $GEO
  perl -0pi -e 's/(        watchers = new HashSet<Watcher>\(\);\n)(        stopSelf\(\);)/$1        stopForeground(true);\n$2/' $GEO
  grep -c "stopForeground(true)" $GEO || true
fi
# Alarmes tocam no volume de ALARME do celular (e não no de notificação)
sed -i 's/AudioAttributes.USAGE_NOTIFICATION/AudioAttributes.USAGE_ALARM/' node_modules/@capacitor/local-notifications/android/src/main/java/com/capacitorjs/plugins/localnotifications/NotificationChannelManager.java
grep -c USAGE_ALARM node_modules/@capacitor/local-notifications/android/src/main/java/com/capacitorjs/plugins/localnotifications/NotificationChannelManager.java || true
npx cap add android
npx cap sync android
RES=android/app/src/main/res

# Se o Android matar a parte que desenha a tela (WebView) em segundo plano, recria a tela em vez de ficar branca
cat > android/app/src/main/java/com/treinoplus/app/MainActivity.java <<'JAVA'
package com.treinoplus.app;

import android.os.Bundle;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebView;
import com.getcapacitor.BridgeActivity;
import com.getcapacitor.WebViewListener;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        bridge.addWebViewListener(new WebViewListener() {
            @Override
            public boolean onRenderProcessGone(WebView webView, RenderProcessGoneDetail detail) {
                try { recreate(); } catch (Throwable ignored) {}
                return true;
            }
        });
    }
}
JAVA
command -v convert > /dev/null || sudo apt-get install -y -qq imagemagick > /dev/null

# Icone do app
rm -rf $RES/mipmap-anydpi-v26
for d in $RES/mipmap-*; do
  cp www/icons/icon-512.png $d/ic_launcher.png
  cp www/icons/icon-512.png $d/ic_launcher_round.png
  rm -f $d/ic_launcher_foreground.png
done

# Tela de abertura escura com o logo
LOGO=www/icons/splash-logo.png; [ -f $LOGO ] || LOGO=www/icons/icon-512.png
for f in $(find $RES -name splash.png); do
  S=$(identify -format '%wx%h' "$f")
  convert -size "$S" xc:'#0D0D0D' \( $LOGO -resize 320x320 \) -gravity center -composite "$f"
done

# Ícone pequeno das notificações (silhueta branca do logo)
LOGO2=www/icons/splash-logo.png; [ -f $LOGO2 ] || LOGO2=www/icons/icon-192.png
for spec in mdpi:24 hdpi:36 xhdpi:48 xxhdpi:72 xxxhdpi:96; do
  mkdir -p $RES/drawable-${spec%%:*}
  convert $LOGO2 -resize ${spec##*:}x${spec##*:} -background none -gravity center -extent ${spec##*:}x${spec##*:} -fill white -colorize 100 $RES/drawable-${spec%%:*}/ic_stat_treino.png
done

# Sons dos alarmes
if ls www/sounds/*.wav > /dev/null 2>&1; then mkdir -p $RES/raw && cp www/sounds/*.wav $RES/raw/ && ls $RES/raw; fi

# Permissões extras: alarme na hora exata (lembretes e fim do descanso)
MAN=android/app/src/main/AndroidManifest.xml
sed -i 's#</manifest>#    <uses-permission android:name="android.permission.USE_EXACT_ALARM"/>\n    <uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM" android:maxSdkVersion="32"/>\n</manifest>#' $MAN
grep -c EXACT_ALARM $MAN

# Barras do sistema escuras
sed -i 's#<item name="android:background">@null</item>#<item name="android:background">@null</item><item name="android:statusBarColor">\#0D0D0D</item><item name="android:navigationBarColor">\#0D0D0D</item><item name="android:windowLightStatusBar">false</item><item name="android:forceDarkAllowed">false</item><item name="android:windowBackground">@android:color/black</item>#' $RES/values/styles.xml

# Versao do app
sed -i "s/versionCode 1/versionCode $RUN/; s/versionName \"1.0\"/versionName \"1.$RUN\"/" android/app/build.gradle

# Não deixar avisos de "lint" travarem a montagem
cat >> android/app/build.gradle <<'GRADLE'

android {
    lint {
        checkReleaseBuilds false
        abortOnError false
    }
}
GRADLE

# Compilar (se um plugin der problema, tenta de novo sem ele para o app sair mesmo assim)
cd android
chmod +x gradlew
build() { ./gradlew assembleRelease --no-daemon --console=plain -q; }
if ! build; then
  echo "::warning::Falhou com o GPS em segundo plano. Tentando sem esse plugin..."
  (cd .. && npm uninstall @capacitor-community/background-geolocation && npx cap sync android)
  if ! build; then
    echo "::warning::Falhou de novo. Tentando sem os alarmes..."
    (cd .. && npm uninstall @capacitor/local-notifications && npx cap sync android)
    build
  fi
fi

# Assinar
BT=$(ls -d $ANDROID_HOME/build-tools/* | sort -V | tail -1)
$BT/zipalign -f 4 app/build/outputs/apk/release/app-release-unsigned.apk aligned.apk
$BT/apksigner sign --ks ../../site/apk/chave.keystore --ks-pass pass:treinoplus --key-pass pass:treinoplus --ks-key-alias treino --out ../../TREINO-plus.apk aligned.apk
ls -la ../../TREINO-plus.apk
echo "Plugins no app:"; cat app/src/main/assets/capacitor.plugins.json
