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
t=t.replace('versionCode 1\n        versionName "1.0"','versionCode 14\n        versionName "1.4.0"')
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
# ---- widget da tela inicial (código nativo Android)
JAVA=android/app/src/main/java/app/atelas/client
mkdir -p "$JAVA" android/app/src/main/res/layout android/app/src/main/res/xml android/app/src/main/res/drawable android/app/src/main/res/values

cat > "$JAVA/MainActivity.java" <<'EOF'
package app.atelas.client;

import android.os.Bundle;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(AtelasWidgetPlugin.class);
        super.onCreate(savedInstanceState);
    }
}
EOF

cat > "$JAVA/AtelasWidgetPlugin.java" <<'EOF'
package app.atelas.client;

import android.content.Context;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

@CapacitorPlugin(name = "AtelasWidget")
public class AtelasWidgetPlugin extends Plugin {
    @PluginMethod
    public void update(PluginCall call) {
        String json = call.getString("json", "{}");
        getContext().getSharedPreferences("atelas_widget", Context.MODE_PRIVATE)
            .edit().putString("data", json).apply();
        AtelasWidgetProvider.refreshAll(getContext());
        call.resolve();
    }
}
EOF

cat > "$JAVA/AtelasWidgetProvider.java" <<'EOF'
package app.atelas.client;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.widget.RemoteViews;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import org.json.JSONArray;
import org.json.JSONObject;

public class AtelasWidgetProvider extends AppWidgetProvider {
    @Override
    public void onUpdate(Context context, AppWidgetManager mgr, int[] ids) {
        for (int id : ids) render(context, mgr, id);
    }

    static void refreshAll(Context context) {
        AppWidgetManager mgr = AppWidgetManager.getInstance(context);
        int[] ids = mgr.getAppWidgetIds(new ComponentName(context, AtelasWidgetProvider.class));
        for (int id : ids) render(context, mgr, id);
    }

    static void render(Context context, AppWidgetManager mgr, int id) {
        RemoteViews rv = new RemoteViews(context.getPackageName(), R.layout.atelas_widget);
        Locale pt = new Locale("pt", "BR");
        Date now = new Date();
        String key = new SimpleDateFormat("yyyy-MM-dd", Locale.US).format(now);
        rv.setTextViewText(R.id.wg_title, new SimpleDateFormat("EEEE, d 'de' MMMM", pt).format(now));
        String body;
        String extra = "";
        try {
            String raw = context.getSharedPreferences("atelas_widget", Context.MODE_PRIVATE).getString("data", null);
            if (raw == null) {
                body = "Abra o Atelas para ativar o widget.";
            } else {
                JSONObject o = new JSONObject(raw);
                JSONObject days = o.optJSONObject("days");
                JSONArray arr = days == null ? null : days.optJSONArray(key);
                if (arr == null) {
                    body = "Abra o Atelas para atualizar.";
                } else if (arr.length() == 0) {
                    body = "Nada marcado para hoje.";
                } else {
                    StringBuilder sb = new StringBuilder();
                    for (int i = 0; i < arr.length(); i++) {
                        if (i > 0) sb.append("\n");
                        sb.append("• ").append(arr.optString(i));
                    }
                    body = sb.toString();
                }
                extra = o.optString("extra", "");
            }
        } catch (Exception e) {
            body = "Abra o Atelas para atualizar.";
        }
        rv.setTextViewText(R.id.wg_body, body);
        rv.setTextViewText(R.id.wg_extra, extra);
        Intent launch = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        if (launch != null) {
            PendingIntent pi = PendingIntent.getActivity(context, 0, launch,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
            rv.setOnClickPendingIntent(R.id.wg_root, pi);
        }
        mgr.updateAppWidget(id, rv);
    }
}
EOF

cat > android/app/src/main/res/layout/atelas_widget.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:id="@+id/wg_root"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:orientation="vertical"
    android:padding="14dp"
    android:background="@drawable/widget_bg">
    <TextView
        android:id="@+id/wg_title"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:textColor="#FFFFFF"
        android:textSize="15sp"
        android:textStyle="bold"
        android:maxLines="1" />
    <TextView
        android:id="@+id/wg_body"
        android:layout_width="match_parent"
        android:layout_height="0dp"
        android:layout_weight="1"
        android:layout_marginTop="6dp"
        android:textColor="#E6E6E6"
        android:textSize="13sp"
        android:ellipsize="end" />
    <TextView
        android:id="@+id/wg_extra"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:textColor="#A0A0A0"
        android:textSize="12sp"
        android:maxLines="1" />
</LinearLayout>
EOF

cat > android/app/src/main/res/drawable/widget_bg.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <solid android:color="#F2000000" />
    <corners android:radius="22dp" />
    <stroke android:width="1dp" android:color="#33FFFFFF" />
</shape>
EOF

cat > android/app/src/main/res/xml/atelas_widget_info.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<appwidget-provider xmlns:android="http://schemas.android.com/apk/res/android"
    android:minWidth="250dp"
    android:minHeight="110dp"
    android:targetCellWidth="4"
    android:targetCellHeight="2"
    android:updatePeriodMillis="1800000"
    android:initialLayout="@layout/atelas_widget"
    android:resizeMode="horizontal|vertical"
    android:widgetCategory="home_screen"
    android:description="@string/widget_desc" />
EOF

cat > android/app/src/main/res/values/atelas_widget_strings.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="widget_desc">Seus avisos do dia na tela inicial</string>
</resources>
EOF

python3 - <<'PY'
p='android/app/src/main/AndroidManifest.xml'
t=open(p).read()
rec="""
        <receiver android:name=".AtelasWidgetProvider" android:exported="false">
            <intent-filter>
                <action android:name="android.appwidget.action.APPWIDGET_UPDATE" />
            </intent-filter>
            <meta-data android:name="android.appwidget.provider" android:resource="@xml/atelas_widget_info" />
        </receiver>
"""
assert t.count('</application>')==1
t=t.replace('</application>',rec+'    </application>',1)
open(p,'w').write(t)
PY

npx capacitor-assets generate --android
npx cap sync android
chmod +x android/gradlew
./android/gradlew -p android assembleRelease
