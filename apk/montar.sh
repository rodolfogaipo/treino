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
# arquivo antigo com fichas pessoais: nunca vai para dentro do app
rm -f www/minhas-fichas.json
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
  # pedido "treino-limpar": desliga TODO GPS que tenha sobrado e tira a notificação
  perl -0pi -e 's/(        void removeWatcher\(String id\) \{\n)/$1            if ("treino-limpar".equals(id)) { onUnbind(null); return; }\n/' $GEO
  grep -c "treino-limpar" $GEO || true
  # guarda cada ponto do GPS num arquivo (o app recupera o percurso se a tela morrer em segundo plano)
  perl -0pi -e 's/(                    Location location = locationResult.getLastLocation\(\);\n)/$1                    treinoLog(location, BackgroundGeolocationService.this);\n/' $GEO
  perl -0pi -e 's/(    Notification getNotification\(\) \{)/    static void treinoLog(Location l, android.content.Context c) {\n        if (l == null || c == null) return;\n        try {\n            String s = l.getTime() + "," + l.getLatitude() + "," + l.getLongitude() + "," + l.getAccuracy() + "," + (l.hasAltitude() ? String.valueOf(l.getAltitude()) : "") + "," + (l.hasSpeed() ? String.valueOf(l.getSpeed()) : "") + "\\n";\n            java.io.FileOutputStream o = new java.io.FileOutputStream(new java.io.File(c.getFilesDir(), "treino-gps.txt"), true);\n            o.write(s.getBytes());\n            o.close();\n        } catch (Throwable ignored) {}\n    }\n\n$1/' $GEO
  grep -c "treinoLog" $GEO || true
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
import android.os.Handler;
import android.os.Looper;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebView;
import com.getcapacitor.BridgeActivity;
import com.getcapacitor.WebViewListener;

public class MainActivity extends BridgeActivity {
    // a tela (WebView) morreu em segundo plano: recria quando o app voltar (o GPS continua gravando)
    static boolean gone = false;
    static boolean visible = false;
    static int check = 0;
    private final Handler handler = new Handler(Looper.getMainLooper());

    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(TreinoNative.class);
        super.onCreate(savedInstanceState);
        bridge.addWebViewListener(new WebViewListener() {
            @Override
            public boolean onRenderProcessGone(WebView webView, RenderProcessGoneDetail detail) {
                if (visible) { try { recreate(); } catch (Throwable ignored) {} }
                else gone = true;
                return true;
            }
        });
    }

    @Override
    public void onResume() {
        super.onResume();
        visible = true;
        if (gone) { gone = false; try { recreate(); } catch (Throwable ignored) {} return; }
        // ao voltar, confere se a tela está desenhando; se não responder, recria (em vez de ficar preta)
        final int my = ++check;
        handler.postDelayed(() -> {
            if (my != check || isFinishing()) return;
            final boolean[] answered = { false }, bad = { false };
            try {
                bridge.getWebView().evaluateJavascript("(window.__treinoOk?window.__treinoOk():1)", v -> { answered[0] = true; bad[0] = "0".equals(v); });
            } catch (Throwable ignored) {}
            handler.postDelayed(() -> {
                if (my != check || isFinishing()) return;
                if (!answered[0] || bad[0]) { try { recreate(); } catch (Throwable ignored) {} }
            }, 1600);
        }, 400);
    }

    @Override
    public void onPause() {
        visible = false;
        check++;
        super.onPause();
    }
}
JAVA

# Guia de voz (fala os km e o roteiro) + widget da tela inicial
JD=android/app/src/main/java/com/treinoplus/app
cat > $JD/TreinoNative.java <<'JAVA'
package com.treinoplus.app;

import android.appwidget.AppWidgetManager;
import android.content.ComponentName;
import android.content.Context;
import android.content.SharedPreferences;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.os.Build;
import android.os.Bundle;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import java.util.ArrayList;
import java.util.Locale;

/** TREINO+: voz do guia de corrida (abaixa a música enquanto fala) e dados do widget da tela inicial. */
@CapacitorPlugin(name = "TreinoNative")
public class TreinoNative extends Plugin implements TextToSpeech.OnInitListener {
    private TextToSpeech tts;
    private boolean ready = false;
    private boolean failed = false;
    private final ArrayList<String> pending = new ArrayList<String>();
    private AudioManager am;
    private AudioFocusRequest focusReq;
    private int speaking = 0;

    @Override
    public void load() {
        am = (AudioManager) getContext().getSystemService(Context.AUDIO_SERVICE);
    }

    private void ensure() {
        if (tts == null && !failed) {
            try { tts = new TextToSpeech(getContext(), this); } catch (Throwable t) { failed = true; }
        }
    }

    @Override
    public void onInit(int status) {
        if (status != TextToSpeech.SUCCESS || tts == null) { failed = true; return; }
        try {
            int r = tts.setLanguage(new Locale("pt", "BR"));
            if (r == TextToSpeech.LANG_MISSING_DATA || r == TextToSpeech.LANG_NOT_SUPPORTED) tts.setLanguage(new Locale("pt"));
            tts.setSpeechRate(1.05f);
            tts.setOnUtteranceProgressListener(new UtteranceProgressListener() {
                @Override public void onStart(String id) {}
                @Override public void onDone(String id) { done(); }
                @Override public void onError(String id) { done(); }
            });
        } catch (Throwable ignored) {}
        ready = true;
        for (String s : pending) say(s);
        pending.clear();
    }

    private synchronized void done() {
        speaking = Math.max(0, speaking - 1);
        if (speaking == 0) abandon();
    }

    private void focus() {
        if (am == null) return;
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                if (focusReq == null) {
                    AudioAttributes aa = new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build();
                    focusReq = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK).setAudioAttributes(aa).build();
                }
                am.requestAudioFocus(focusReq);
            } else {
                am.requestAudioFocus(null, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK);
            }
        } catch (Throwable ignored) {}
    }

    private void abandon() {
        if (am == null) return;
        try {
            if (Build.VERSION.SDK_INT >= 26) { if (focusReq != null) am.abandonAudioFocusRequest(focusReq); }
            else am.abandonAudioFocus(null);
        } catch (Throwable ignored) {}
    }

    private synchronized void say(String text) {
        if (tts == null) return;
        try {
            if (Build.VERSION.SDK_INT >= 21) {
                AudioAttributes aa = new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build();
                tts.setAudioAttributes(aa);
            }
            speaking++;
            focus();
            Bundle b = new Bundle();
            tts.speak(text, TextToSpeech.QUEUE_ADD, b, "t" + System.nanoTime());
        } catch (Throwable t) { done(); }
    }

    @PluginMethod
    public void speak(PluginCall call) {
        String text = call.getString("text", "");
        if (text == null || text.length() == 0) { call.resolve(); return; }
        ensure();
        if (failed) { call.reject("sem voz"); return; }
        if (ready) say(text); else pending.add(text);
        call.resolve();
    }

    @PluginMethod
    public void isAvailable(PluginCall call) {
        ensure();
        JSObject r = new JSObject();
        r.put("value", !failed);
        call.resolve(r);
    }

    @PluginMethod
    public void stop(PluginCall call) {
        try { if (tts != null) tts.stop(); } catch (Throwable ignored) {}
        speaking = 0;
        abandon();
        call.resolve();
    }

    /** Guarda os dados do widget e manda redesenhar. */
    @PluginMethod
    public void updateWidget(PluginCall call) {
        String data = call.getString("data", "{}");
        Context c = getContext();
        SharedPreferences p = c.getSharedPreferences("treino_widget", Context.MODE_PRIVATE);
        p.edit().putString("data", data).apply();
        try {
            AppWidgetManager m = AppWidgetManager.getInstance(c);
            int[] ids = m.getAppWidgetIds(new ComponentName(c, TreinoWidget.class));
            if (ids != null && ids.length > 0) TreinoWidget.draw(c, m, ids);
        } catch (Throwable ignored) {}
        call.resolve();
    }

    @Override
    protected void handleOnDestroy() {
        try { if (tts != null) tts.shutdown(); } catch (Throwable ignored) {}
        tts = null; ready = false;
    }
}
JAVA
cat > $JD/TreinoWidget.java <<'JAVA'
package com.treinoplus.app;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.text.SpannableStringBuilder;
import android.text.Spanned;
import android.text.style.ForegroundColorSpan;
import android.widget.RemoteViews;
import org.json.JSONArray;
import org.json.JSONObject;

/** TREINO+: widget da tela inicial (sequência, treino do dia, semana e água). Toque abre o app. */
public class TreinoWidget extends AppWidgetProvider {
    @Override
    public void onUpdate(Context c, AppWidgetManager m, int[] ids) {
        draw(c, m, ids);
    }

    private static int id(Context c, String name) {
        return c.getResources().getIdentifier(name, "id", c.getPackageName());
    }

    static void draw(Context c, AppWidgetManager m, int[] ids) {
        String pkg = c.getPackageName();
        int layout = c.getResources().getIdentifier("treino_widget", "layout", pkg);
        if (layout == 0) return;
        JSONObject d;
        try { d = new JSONObject(c.getSharedPreferences("treino_widget", Context.MODE_PRIVATE).getString("data", "{}")); }
        catch (Throwable t) { d = new JSONObject(); }
        int green = Color.parseColor("#00E676");
        int dim = Color.parseColor("#4A4A4A");
        for (int wid : ids) {
            try {
                RemoteViews v = new RemoteViews(pkg, layout);
                int streak = d.optInt("streak", 0);
                v.setTextViewText(id(c, "w_streak"), streak > 0 ? ("🔥 " + streak + (streak == 1 ? " dia" : " dias")) : "🔥 0");
                v.setTextViewText(id(c, "w_today"), d.optString("today", "Abra o app para começar"));
                // semana: letras + bolinhas (verde = treinou)
                JSONArray wk = d.optJSONArray("week");
                String letters = d.optString("letters", "SEGTERQUAQUISEXSABDOM");
                SpannableStringBuilder sb = new SpannableStringBuilder();
                for (int i = 0; i < 7; i++) {
                    boolean on = wk != null && wk.optBoolean(i, false);
                    boolean today = d.optInt("todayIdx", -1) == i;
                    int st = sb.length();
                    sb.append(on ? "●" : (today ? "○" : "●"));
                    sb.setSpan(new ForegroundColorSpan(on ? green : (today ? Color.WHITE : dim)), st, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                    if (i < 6) sb.append("  ");
                }
                v.setTextViewText(id(c, "w_week"), sb);
                v.setTextViewText(id(c, "w_weeklbl"), d.optString("weekLabel", "Semana"));
                v.setTextViewText(id(c, "w_water"), d.optString("water", ""));
                v.setTextViewText(id(c, "w_extra"), d.optString("extra", ""));
                Intent open = c.getPackageManager().getLaunchIntentForPackage(pkg);
                if (open != null) {
                    open.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
                    PendingIntent pi = PendingIntent.getActivity(c, 0, open, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
                    v.setOnClickPendingIntent(id(c, "w_root"), pi);
                }
                m.updateAppWidget(wid, v);
            } catch (Throwable ignored) {}
        }
    }
}
JAVA
mkdir -p $RES/layout $RES/xml $RES/drawable
cat > $RES/layout/treino_widget.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:id="@+id/w_root"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:background="@drawable/treino_widget_bg"
    android:orientation="vertical"
    android:padding="14dp">
    <LinearLayout android:layout_width="match_parent" android:layout_height="wrap_content" android:orientation="horizontal" android:gravity="center_vertical">
        <TextView android:id="@+id/w_title" android:layout_width="0dp" android:layout_weight="1" android:layout_height="wrap_content"
            android:text="TREINO+" android:textColor="#FFFFFFFF" android:textSize="16sp" android:textStyle="bold|italic" />
        <TextView android:id="@+id/w_streak" android:layout_width="wrap_content" android:layout_height="wrap_content"
            android:text="" android:textColor="#FFFF6D00" android:textSize="15sp" android:textStyle="bold" />
    </LinearLayout>
    <TextView android:id="@+id/w_today" android:layout_width="match_parent" android:layout_height="wrap_content" android:layout_marginTop="4dp"
        android:text="Abra o app para começar" android:textColor="#FF00E676" android:textSize="14sp" android:textStyle="bold" android:maxLines="1" android:ellipsize="end" />
    <TextView android:id="@+id/w_extra" android:layout_width="match_parent" android:layout_height="wrap_content"
        android:text="" android:textColor="#FFB0B0B0" android:textSize="12sp" android:maxLines="1" android:ellipsize="end" />
    <LinearLayout android:layout_width="match_parent" android:layout_height="wrap_content" android:orientation="horizontal" android:gravity="center_vertical" android:layout_marginTop="6dp">
        <TextView android:id="@+id/w_weeklbl" android:layout_width="wrap_content" android:layout_height="wrap_content"
            android:text="Semana" android:textColor="#FFB0B0B0" android:textSize="12sp" android:layout_marginEnd="8dp" />
        <TextView android:id="@+id/w_week" android:layout_width="0dp" android:layout_weight="1" android:layout_height="wrap_content"
            android:text="" android:textSize="15sp" />
        <TextView android:id="@+id/w_water" android:layout_width="wrap_content" android:layout_height="wrap_content"
            android:text="" android:textColor="#FF29B6F6" android:textSize="12sp" android:textStyle="bold" />
    </LinearLayout>
</LinearLayout>
XML
cat > $RES/xml/treino_widget_info.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<appwidget-provider xmlns:android="http://schemas.android.com/apk/res/android"
    android:minWidth="250dp"
    android:minHeight="100dp"
    android:minResizeWidth="180dp"
    android:minResizeHeight="80dp"
    android:targetCellWidth="4"
    android:targetCellHeight="2"
    android:updatePeriodMillis="0"
    android:initialLayout="@layout/treino_widget"
    android:previewImage="@mipmap/ic_launcher"
    android:resizeMode="horizontal|vertical"
    android:widgetCategory="home_screen" />
XML
cat > $RES/drawable/treino_widget_bg.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <solid android:color="#F2121212" />
    <stroke android:width="1dp" android:color="#3300E676" />
    <corners android:radius="22dp" />
</shape>
XML
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
# widget + voz (o Android 11+ só deixa usar a voz se o app declarar)
sed -i 's#</application>#    <receiver android:name="com.treinoplus.app.TreinoWidget" android:exported="true" android:label="TREINO+"><intent-filter><action android:name="android.appwidget.action.APPWIDGET_UPDATE"/></intent-filter><meta-data android:name="android.appwidget.provider" android:resource="@xml/treino_widget_info"/></receiver>\n    </application>\n    <queries><intent><action android:name="android.intent.action.TTS_SERVICE"/></intent></queries>#' $MAN
grep -c TreinoWidget $MAN

# Barras do sistema escuras
sed -i 's#<item name="android:background">@null</item>#<item name="android:background">@null</item><item name="android:statusBarColor">\#0D0D0D</item><item name="android:navigationBarColor">\#0D0D0D</item><item name="android:windowLightStatusBar">false</item><item name="android:forceDarkAllowed">false</item><item name="android:windowBackground">@drawable/treino_bg</item>#' $RES/values/styles.xml
# fundo da janela: escuro com o logo (aparece em vez de preto se a tela demorar para voltar)
cat > $RES/drawable/treino_bg.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item><color android:color="#ff0d0d0d" /></item>
    <item><bitmap android:gravity="center" android:src="@drawable/splash" /></item>
</layer-list>
XML

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
