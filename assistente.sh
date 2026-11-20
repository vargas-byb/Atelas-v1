#!/bin/bash
# Mibo como assistente do celular + "Hey Mibo" (escuta offline com Vosk).
# Chamado pelo build.sh depois do widgets.sh.
set -e
JAVA=android/app/src/main/java/app/atelas/client
RES=android/app/src/main/res
ASSETS=android/app/src/main/assets
mkdir -p "$JAVA" $RES/xml $RES/values "$ASSETS"

# ---- modelo de voz offline (português, ~30 MB). Se o download falhar o APK sai igual, sem o "Hey Mibo".
if [ ! -d "$ASSETS/model" ]; then
  if curl -fL --retry 3 -o /tmp/vosk-pt.zip https://alphacephei.com/vosk/models/vosk-model-small-pt-0.3.zip \
     && unzip -q /tmp/vosk-pt.zip -d /tmp/vosk-pt && mv /tmp/vosk-pt/vosk-model-small-pt-0.3 "$ASSETS/model"; then
    echo "Modelo de voz incluído."
  else
    echo "::warning::Não consegui baixar o modelo de voz. O APK sai sem o Hey Mibo."
  fi
fi

cat > "$JAVA/HotwordService.java" <<'EOF'
package app.atelas.client;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ServiceInfo;
import android.content.res.AssetManager;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.VibrationEffect;
import android.os.Vibrator;
import androidx.core.app.NotificationCompat;
import androidx.core.content.ContextCompat;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.text.Normalizer;
import java.util.Locale;
import java.util.regex.Pattern;
import org.json.JSONObject;
import org.vosk.Model;
import org.vosk.Recognizer;
import org.vosk.android.RecognitionListener;
import org.vosk.android.SpeechService;

/** Escuta só a palavra de ativação "Hey Mibo", offline, e abre a Mibo ao vivo. */
public class HotwordService extends Service implements RecognitionListener {
    static final String PREFS = "atelas_assistant";
    static final String ACTION_STOP = "app.atelas.client.HOTWORD_STOP";
    static final String ACTION_LIVE = "app.atelas.client.MIBO_LIVE";
    static final String CH_FG = "hotword";
    static final String CH_CALL = "hotword_call";
    static HotwordService inst;

    private final Handler main = new Handler(Looper.getMainLooper());
    private Model model;
    private Recognizer rec;
    private SpeechService speech;
    private boolean paused = false, loading = false, dead = false;
    private long lastFire = 0;
    private final Runnable autoResume = new Runnable() { public void run() { pause(false); } };

    private static final Pattern PAT = Pattern.compile(
        "\\b(hey|hei|ei|ey|oi|ola|ok|okay|e ai|ai|hay|rei)\\s*(mi+\\s?bo+u?|mim\\s?bo+|mi\\s?bom|mibu|meebo|mimbo)\\b|^mi\\s?bo+u?$");

    static boolean heard(String raw) {
        if (raw == null || raw.isEmpty()) return false;
        String s = Normalizer.normalize(raw.toLowerCase(Locale.ROOT), Normalizer.Form.NFD)
            .replaceAll("\\p{M}", "").replaceAll("[^a-z ]", " ").replaceAll("\\s+", " ").trim();
        return PAT.matcher(s).find();
    }

    static boolean enabled(Context c) {
        return c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("hotword", false);
    }

    static void setEnabled(Context c, boolean on) {
        c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("hotword", on).apply();
    }

    static boolean hasModel(Context c) {
        try { String[] l = c.getAssets().list("model"); return l != null && l.length > 0; }
        catch (Exception e) { return false; }
    }

    static void start(Context c) {
        try { ContextCompat.startForegroundService(c, new Intent(c, HotwordService.class)); } catch (Exception e) {}
    }

    static void stop(Context c) {
        try { c.stopService(new Intent(c, HotwordService.class)); } catch (Exception e) {}
    }

    /** Segura ou libera o microfone (a conversa ao vivo precisa dele). */
    static void pause(final boolean p) {
        final HotwordService s = inst;
        if (s == null) return;
        s.main.post(new Runnable() { public void run() { s.setPaused(p); } });
    }

    static Intent liveIntent(Context c) {
        Intent i = new Intent(c, MiboOverlayActivity.class);
        i.setAction(ACTION_LIVE);
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_NO_ANIMATION);
        return i;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        inst = this;
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel a = new NotificationChannel(CH_FG, "Hey Mibo", NotificationManager.IMPORTANCE_LOW);
            a.setDescription("Mostra que o Hey Mibo está ouvindo a palavra de ativação");
            nm.createNotificationChannel(a);
            NotificationChannel b = new NotificationChannel(CH_CALL, "Mibo chamada", NotificationManager.IMPORTANCE_HIGH);
            b.setDescription("Abre a Mibo quando você diz Hey Mibo");
            nm.createNotificationChannel(b);
        }
    }

    private Notification fgNotification(String text) {
        Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent open = PendingIntent.getActivity(this, 11, launch != null ? launch : liveIntent(this), PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Intent st = new Intent(this, HotwordService.class).setAction(ACTION_STOP);
        PendingIntent stop = PendingIntent.getService(this, 12, st, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        return new NotificationCompat.Builder(this, CH_FG)
            .setSmallIcon(R.drawable.ic_stat_icon)
            .setContentTitle("Hey Mibo ativo")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(0, "Desativar", stop)
            .build();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_STOP.equals(intent.getAction())) {
            setEnabled(this, false);
            stopSelf();
            return START_NOT_STICKY;
        }
        String txt = hasModel(this) ? "Diga \"Hey Mibo\" para falar com a Mibo." : "Modelo de voz ausente neste APK.";
        Notification n = fgNotification(txt);
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(31, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE);
            else startForeground(31, n);
        } catch (Exception e) { stopSelf(); return START_NOT_STICKY; }
        if (!hasModel(this)) return START_NOT_STICKY;
        if (model == null && !loading) loadModel();
        else if (model != null && speech == null && !paused) listen();
        return START_STICKY;
    }

    private void loadModel() {
        loading = true;
        new Thread(new Runnable() {
            public void run() {
                try {
                    File dir = new File(getFilesDir(), "vosk-model");
                    File ok = new File(dir, ".ok");
                    if (!ok.exists()) {
                        copyAssets(getAssets(), "model", dir);
                        new FileOutputStream(ok).close();
                    }
                    final Model m = new Model(dir.getAbsolutePath());
                    main.post(new Runnable() { public void run() {
                        loading = false;
                        if (dead) { m.close(); return; }
                        model = m;
                        if (!paused) listen();
                    }});
                } catch (Exception e) {
                    loading = false;
                    main.post(new Runnable() { public void run() { stopSelf(); } });
                }
            }
        }).start();
    }

    private static void copyAssets(AssetManager am, String from, File to) throws Exception {
        String[] kids = am.list(from);
        if (kids == null || kids.length == 0) {
            to.getParentFile().mkdirs();
            InputStream in = am.open(from);
            OutputStream out = new FileOutputStream(to);
            byte[] buf = new byte[65536];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            out.close(); in.close();
            return;
        }
        to.mkdirs();
        for (String k : kids) copyAssets(am, from + "/" + k, new File(to, k));
    }

    private void listen() {
        if (model == null || speech != null || dead) return;
        try {
            rec = new Recognizer(model, 16000.0f);
            speech = new SpeechService(rec, 16000.0f);
            speech.startListening(this);
        } catch (Exception e) {
            release();
            main.postDelayed(new Runnable() { public void run() { if (!paused) listen(); } }, 5000);
        }
    }

    private void release() {
        try { if (speech != null) { speech.stop(); speech.shutdown(); } } catch (Exception e) {}
        try { if (rec != null) rec.close(); } catch (Exception e) {}
        speech = null; rec = null;
    }

    private void setPaused(boolean p) {
        main.removeCallbacks(autoResume);
        paused = p;
        if (p) release();
        else if (model != null && !dead) listen();
    }

    private void fire() {
        long now = System.currentTimeMillis();
        if (now - lastFire < 5000) return;
        lastFire = now;
        setPaused(true);
        main.postDelayed(autoResume, 25000);
        try {
            Vibrator v = (Vibrator) getSystemService(VIBRATOR_SERVICE);
            if (v != null) {
                if (Build.VERSION.SDK_INT >= 26) v.vibrate(VibrationEffect.createOneShot(90, VibrationEffect.DEFAULT_AMPLITUDE));
                else v.vibrate(90);
            }
        } catch (Exception e) {}
        Intent i = liveIntent(this);
        try { startActivity(i); } catch (Exception e) {}
        /* se o Android bloquear a abertura em segundo plano, um aviso em tela cheia abre a Mibo */
        try {
            PendingIntent pi = PendingIntent.getActivity(this, 13, i, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
            Notification n = new NotificationCompat.Builder(this, CH_CALL)
                .setSmallIcon(R.drawable.ic_stat_icon)
                .setContentTitle("Mibo")
                .setContentText("Toque para falar com a Mibo")
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setFullScreenIntent(pi, true)
                .setContentIntent(pi)
                .setAutoCancel(true)
                .setTimeoutAfter(20000)
                .build();
            ((NotificationManager) getSystemService(NOTIFICATION_SERVICE)).notify(32, n);
        } catch (Exception e) {}
    }

    private void check(String json, String key) {
        try {
            String t = new JSONObject(json).optString(key, "");
            if (heard(t)) fire();
        } catch (Exception e) {}
    }

    @Override public void onPartialResult(String h) { check(h, "partial"); }
    @Override public void onResult(String h) { check(h, "text"); }
    @Override public void onFinalResult(String h) { check(h, "text"); }
    @Override public void onError(Exception e) {
        release();
        main.postDelayed(new Runnable() { public void run() { if (!paused) listen(); } }, 4000);
    }
    @Override public void onTimeout() {}

    @Override public IBinder onBind(Intent i) { return null; }

    @Override
    public void onDestroy() {
        dead = true;
        inst = null;
        main.removeCallbacksAndMessages(null);
        release();
        try { if (model != null) model.close(); } catch (Exception e) {}
        model = null;
        super.onDestroy();
    }
}
EOF

cat > "$JAVA/AtelasAssistantPlugin.java" <<'EOF'
package app.atelas.client;

import android.Manifest;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.provider.Settings;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

@CapacitorPlugin(name = "AtelasAssistant")
public class AtelasAssistantPlugin extends Plugin {
    private boolean mic() {
        return getContext().checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED;
    }

    @PluginMethod
    public void status(PluginCall call) {
        Context c = getContext();
        JSObject o = new JSObject();
        o.put("hotword", HotwordService.enabled(c));
        o.put("running", HotwordService.inst != null);
        o.put("mic", mic());
        o.put("model", HotwordService.hasModel(c));
        boolean ov = false;
        try { ov = Settings.canDrawOverlays(c); } catch (Exception e) {}
        o.put("overlay", ov);
        boolean as = false;
        try {
            String cur = Settings.Secure.getString(c.getContentResolver(), "assistant");
            as = cur != null && cur.startsWith(c.getPackageName() + "/");
        } catch (Exception e) {}
        o.put("assistant", as);
        call.resolve(o);
    }

    /** Liga ou desliga o Hey Mibo. Se faltar o microfone, pede a permissão e devolve ok=false. */
    @PluginMethod
    public void setHotword(PluginCall call) {
        Context c = getContext();
        boolean on = Boolean.TRUE.equals(call.getBoolean("on", false));
        JSObject o = new JSObject();
        if (!on) {
            HotwordService.setEnabled(c, false);
            HotwordService.stop(c);
            o.put("ok", true);
            call.resolve(o);
            return;
        }
        if (!HotwordService.hasModel(c)) { o.put("ok", false); o.put("reason", "model"); call.resolve(o); return; }
        if (!mic()) {
            try { getActivity().requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO, Manifest.permission.POST_NOTIFICATIONS}, 77); } catch (Exception e) {}
            o.put("ok", false); o.put("reason", "mic"); call.resolve(o); return;
        }
        HotwordService.setEnabled(c, true);
        HotwordService.start(c);
        o.put("ok", true);
        call.resolve(o);
    }

    /** Chamado ao abrir o app: religa o serviço se o usuário deixou o Hey Mibo ativo. */
    @PluginMethod
    public void ensure(PluginCall call) {
        Context c = getContext();
        if (HotwordService.enabled(c) && mic() && HotwordService.inst == null && HotwordService.hasModel(c)) HotwordService.start(c);
        call.resolve();
    }

    /** A conversa ao vivo usa o microfone: segura o Hey Mibo enquanto ela está aberta. */
    @PluginMethod
    public void hold(PluginCall call) {
        HotwordService.pause(Boolean.TRUE.equals(call.getBoolean("on", false)));
        call.resolve();
    }

    /** A página pergunta se está rodando dentro da janela flutuante da Mibo. */
    @PluginMethod
    public void mode(PluginCall call) {
        JSObject o = new JSObject();
        o.put("overlay", getActivity() instanceof MiboOverlayActivity);
        call.resolve(o);
    }

    @PluginMethod
    public void reveal(PluginCall call) {
        if (getActivity() instanceof MiboOverlayActivity) ((MiboOverlayActivity) getActivity()).reveal();
        call.resolve();
    }

    @PluginMethod
    public void closeOverlay(PluginCall call) {
        if (getActivity() instanceof MiboOverlayActivity) getActivity().finish();
        call.resolve();
    }

    private void open(PluginCall call, Intent i) {
        try { i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK); getContext().startActivity(i); }
        catch (Exception e) {
            try { Intent f = new Intent(Settings.ACTION_SETTINGS); f.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK); getContext().startActivity(f); } catch (Exception e2) {}
        }
        call.resolve();
    }

    @PluginMethod
    public void openAssistantSettings(PluginCall call) {
        open(call, new Intent(Settings.ACTION_VOICE_INPUT_SETTINGS));
    }

    @PluginMethod
    public void openOverlaySettings(PluginCall call) {
        open(call, new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:" + getContext().getPackageName())));
    }

    @PluginMethod
    public void openBatterySettings(PluginCall call) {
        open(call, new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS));
    }
}
EOF

cat > "$JAVA/MiboOverlayActivity.java" <<'EOF'
package app.atelas.client;

import android.graphics.Color;
import android.os.Bundle;
import android.view.View;
import com.getcapacitor.BridgeActivity;

/** Janela translúcida da Mibo: aparece por cima do app que estiver aberto, como o Google Assistente. */
public class MiboOverlayActivity extends BridgeActivity {
    private boolean shown = false;

    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(AtelasWidgetPlugin.class);
        registerPlugin(AtelasAssistantPlugin.class);
        super.onCreate(savedInstanceState);
        try {
            View w = getBridge().getWebView();
            w.setBackgroundColor(Color.TRANSPARENT);
            w.setAlpha(0f);
            /* se a página demorar, mostra mesmo assim */
            w.postDelayed(new Runnable() { public void run() { reveal(); } }, 4000);
        } catch (Exception e) {}
    }

    void reveal() {
        if (shown) return;
        shown = true;
        try { getBridge().getWebView().animate().alpha(1f).setDuration(160).start(); } catch (Exception e) {}
    }

    @Override
    public void finish() {
        super.finish();
        overridePendingTransition(0, 0);
    }
}
EOF

cat > "$JAVA/MiboVoiceInteractionService.java" <<'EOF'
package app.atelas.client;

import android.service.voice.VoiceInteractionService;

/** Permite escolher o Atelas como "assistente digital" do Android (botão liga/desliga, gesto, Bixby). */
public class MiboVoiceInteractionService extends VoiceInteractionService {
}
EOF

cat > "$JAVA/MiboSessionService.java" <<'EOF'
package app.atelas.client;

import android.os.Bundle;
import android.service.voice.VoiceInteractionSession;
import android.service.voice.VoiceInteractionSessionService;

public class MiboSessionService extends VoiceInteractionSessionService {
    @Override
    public VoiceInteractionSession onNewSession(Bundle args) {
        return new MiboSession(this);
    }
}
EOF

cat > "$JAVA/MiboSession.java" <<'EOF'
package app.atelas.client;

import android.content.Context;
import android.os.Bundle;
import android.service.voice.VoiceInteractionSession;

/** Quando o assistente é chamado, abre direto a Mibo ao vivo. */
public class MiboSession extends VoiceInteractionSession {
    public MiboSession(Context c) { super(c); }

    @Override
    public void onShow(Bundle args, int flags) {
        super.onShow(args, flags);
        try { getContext().startActivity(HotwordService.liveIntent(getContext())); } catch (Exception e) {}
        hide();
        finish();
    }
}
EOF

cat > "$JAVA/MiboRecognitionService.java" <<'EOF'
package app.atelas.client;

import android.content.Intent;
import android.speech.RecognitionService;
import android.speech.SpeechRecognizer;

/** O Android exige este serviço para registrar um assistente. Ele não reconhece nada. */
public class MiboRecognitionService extends RecognitionService {
    @Override protected void onStartListening(Intent i, Callback cb) {
        try { cb.error(SpeechRecognizer.ERROR_CLIENT); } catch (Exception e) {}
    }
    @Override protected void onCancel(Callback cb) {}
    @Override protected void onStopListening(Callback cb) {}
}
EOF

cat > $RES/xml/mibo_interaction.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<voice-interaction-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:sessionService="app.atelas.client.MiboSessionService"
    android:recognitionService="app.atelas.client.MiboRecognitionService"
    android:supportsAssist="true" />
EOF
cat > $RES/values/atelas_overlay.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="MiboOverlay" parent="Theme.AppCompat.Light.NoActionBar">
        <item name="android:windowIsTranslucent">true</item>
        <item name="android:windowBackground">@android:color/transparent</item>
        <item name="android:backgroundDimEnabled">false</item>
        <item name="android:windowNoTitle">true</item>
        <item name="android:windowAnimationStyle">@android:style/Animation.Translucent</item>
        <item name="android:statusBarColor">@android:color/transparent</item>
        <item name="android:navigationBarColor">@android:color/transparent</item>
    </style>
</resources>
EOF
cat > $RES/xml/mibo_recognition.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<recognition-service xmlns:android="http://schemas.android.com/apk/res/android" />
EOF

python3 - <<'PY'
p='android/app/src/main/AndroidManifest.xml'
t=open(p,encoding='utf-8').read()
svc='''
        <activity android:name=".MiboOverlayActivity" android:theme="@style/MiboOverlay" android:launchMode="singleTask" android:taskAffinity="" android:excludeFromRecents="true" android:exported="false" android:configChanges="orientation|keyboardHidden|keyboard|screenSize|locale|smallestScreenSize|screenLayout|uiMode" />
        <service android:name=".HotwordService" android:exported="false" android:foregroundServiceType="microphone" />
        <service android:name=".MiboVoiceInteractionService" android:permission="android.permission.BIND_VOICE_INTERACTION" android:exported="true">
            <meta-data android:name="android.voice_interaction" android:resource="@xml/mibo_interaction" />
            <intent-filter>
                <action android:name="android.service.voice.VoiceInteractionService" />
            </intent-filter>
        </service>
        <service android:name=".MiboSessionService" android:permission="android.permission.BIND_VOICE_INTERACTION" android:exported="true" />
        <service android:name=".MiboRecognitionService" android:exported="true">
            <intent-filter>
                <action android:name="android.speech.RecognitionService" />
                <category android:name="android.intent.category.DEFAULT" />
            </intent-filter>
            <meta-data android:name="android.speech" android:resource="@xml/mibo_recognition" />
        </service>'''
perms='''    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
    <uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT" />
    <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />
'''
assert t.count('</application>')==1 and t.count('</manifest>')==1
t=t.replace('</application>',svc+'\n    </application>',1).replace('</manifest>',perms+'</manifest>',1)
open(p,'w',encoding='utf-8').write(t)

g='android/app/build.gradle'
s=open(g).read()
dep="dependencies {\n    implementation 'com.alphacephei:vosk-android:0.3.47'\n    implementation 'net.java.dev.jna:jna:5.13.0@aar'\n"
assert s.count('\ndependencies {\n')==1
s=s.replace('\ndependencies {\n','\n'+dep,1)
open(g,'w').write(s)
PY
