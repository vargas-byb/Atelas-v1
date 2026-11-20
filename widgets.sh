#!/bin/bash
# Widgets nativos da tela inicial (Hoje 4x2, Calendário 4x2, Saúde 2x2, Sono 2x2) e permissão do microfone.
# Chamado pelo build.sh depois do "npx cap add android".
set -e
JAVA=android/app/src/main/java/app/atelas/client
RES=android/app/src/main/res
mkdir -p "$JAVA" $RES/layout $RES/xml $RES/drawable $RES/values

cat > "$JAVA/MainActivity.java" <<'EOF'
package app.atelas.client;

import android.content.Intent;
import android.os.Bundle;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(AtelasWidgetPlugin.class);
        registerPlugin(AtelasAssistantPlugin.class);
        super.onCreate(savedInstanceState);
        keepTab(getIntent());
    }

    @Override
    public void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        keepTab(intent);
        /* app já aberto: avisa a página para ler o pedido (ex.: abrir a Mibo ao vivo) */
        try {
            getBridge().getWebView().post(new Runnable() {
                public void run() {
                    getBridge().getWebView().evaluateJavascript("window.__atelasTab&&window.__atelasTab()", null);
                }
            });
        } catch (Exception e) {}
    }

    private void keepTab(Intent i) {
        if (i == null) return;
        String t = i.getStringExtra("atelas_tab");
        if (t != null) {
            getSharedPreferences("atelas_widget", MODE_PRIVATE).edit().putString("tab", t).apply();
            i.removeExtra("atelas_tab");
        }
    }
}
EOF

cat > "$JAVA/AtelasWidgetPlugin.java" <<'EOF'
package app.atelas.client;

import android.content.Context;
import android.content.SharedPreferences;
import com.getcapacitor.JSObject;
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
        AtelasWidgets.refreshAll(getContext());
        call.resolve();
    }

    @PluginMethod
    public void consumeTab(PluginCall call) {
        SharedPreferences p = getContext().getSharedPreferences("atelas_widget", Context.MODE_PRIVATE);
        String t = p.getString("tab", "");
        p.edit().remove("tab").apply();
        JSObject o = new JSObject();
        o.put("tab", t);
        call.resolve(o);
    }
}
EOF

cat > "$JAVA/AtelasWidgets.java" <<'EOF'
package app.atelas.client;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import org.json.JSONObject;

class AtelasWidgets {
    static JSONObject data(Context c) {
        try {
            String raw = c.getSharedPreferences("atelas_widget", Context.MODE_PRIVATE).getString("data", null);
            return raw == null ? null : new JSONObject(raw);
        } catch (Exception e) {
            return null;
        }
    }

    static PendingIntent open(Context c, String tab, int code) {
        Intent i = c.getPackageManager().getLaunchIntentForPackage(c.getPackageName());
        if (i == null) return null;
        i.putExtra("atelas_tab", tab);
        return PendingIntent.getActivity(c, code, i, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    static int[] ids(Context c, Class<?> k) {
        return AppWidgetManager.getInstance(c).getAppWidgetIds(new ComponentName(c, k));
    }

    static void refreshAll(Context c) {
        AppWidgetManager m = AppWidgetManager.getInstance(c);
        for (int id : ids(c, AtelasWidgetProvider.class)) AtelasWidgetProvider.render(c, m, id);
        for (int id : ids(c, AtelasCalendarWidget.class)) AtelasCalendarWidget.render(c, m, id);
        for (int id : ids(c, AtelasHealthWidget.class)) AtelasHealthWidget.render(c, m, id);
        for (int id : ids(c, AtelasSleepWidget.class)) AtelasSleepWidget.render(c, m, id);
    }

    static String liters(int ml) {
        if (ml >= 1000) {
            double l = Math.round(ml / 10.0) / 100.0;
            String s = (l == Math.floor(l)) ? String.valueOf((int) l) : String.valueOf(l);
            return s.replace('.', ',') + " L";
        }
        return ml + " ml";
    }

    static String hours(int min) {
        int h = min / 60, m = min % 60;
        return m == 0 ? h + "h" : h + "h" + (m < 10 ? "0" + m : String.valueOf(m));
    }

    static int pct(int v, int goal) {
        if (goal <= 0) return 0;
        return Math.max(0, Math.min(100, (int) Math.round(v * 100.0 / goal)));
    }
}
EOF

cat > "$JAVA/AtelasWidgetProvider.java" <<'EOF'
package app.atelas.client;

import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.Context;
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

    static void render(Context context, AppWidgetManager mgr, int id) {
        RemoteViews rv = new RemoteViews(context.getPackageName(), R.layout.atelas_widget);
        Locale pt = new Locale("pt", "BR");
        Date now = new Date();
        String key = new SimpleDateFormat("yyyy-MM-dd", Locale.US).format(now);
        rv.setTextViewText(R.id.wg_title, new SimpleDateFormat("EEEE, d 'de' MMMM", pt).format(now));
        String body;
        String extra = "";
        try {
            JSONObject o = AtelasWidgets.data(context);
            if (o == null) {
                body = "Abra o Atelas para ativar o widget.";
            } else {
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
        rv.setOnClickPendingIntent(R.id.wg_root, AtelasWidgets.open(context, "home", 10));
        mgr.updateAppWidget(id, rv);
    }
}
EOF

cat > "$JAVA/AtelasCalendarWidget.java" <<'EOF'
package app.atelas.client;

import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.Context;
import android.widget.RemoteViews;
import java.text.SimpleDateFormat;
import java.util.Calendar;
import java.util.Locale;
import org.json.JSONArray;
import org.json.JSONObject;

public class AtelasCalendarWidget extends AppWidgetProvider {
    @Override
    public void onUpdate(Context context, AppWidgetManager mgr, int[] ids) {
        for (int id : ids) render(context, mgr, id);
    }

    static void render(Context c, AppWidgetManager mgr, int id) {
        RemoteViews rv = new RemoteViews(c.getPackageName(), R.layout.atelas_cal_widget);
        Locale pt = new Locale("pt", "BR");
        Calendar now = Calendar.getInstance();
        int y = now.get(Calendar.YEAR), m = now.get(Calendar.MONTH), today = now.get(Calendar.DAY_OF_MONTH);
        String title = new SimpleDateFormat("MMMM yyyy", pt).format(now.getTime());
        rv.setTextViewText(R.id.cal_title, title.substring(0, 1).toUpperCase(pt) + title.substring(1));

        Calendar first = Calendar.getInstance();
        first.set(y, m, 1);
        int offset = first.get(Calendar.DAY_OF_WEEK) - 1;
        int total = first.getActualMaximum(Calendar.DAY_OF_MONTH);

        JSONObject data = AtelasWidgets.data(c);
        boolean[] mark = new boolean[32];
        String agenda = "Abra o Atelas para atualizar.";
        try {
            if (data != null) {
                JSONObject marks = data.optJSONObject("marks");
                JSONArray a = marks == null ? null : marks.optJSONArray(String.format(Locale.US, "%04d-%02d", y, m + 1));
                if (a != null) {
                    for (int i = 0; i < a.length(); i++) {
                        int dd = a.optInt(i);
                        if (dd >= 1 && dd <= 31) mark[dd] = true;
                    }
                }
                JSONObject days = data.optJSONObject("days");
                SimpleDateFormat f = new SimpleDateFormat("yyyy-MM-dd", Locale.US);
                SimpleDateFormat lf = new SimpleDateFormat("EEE d/MM", pt);
                StringBuilder sb = new StringBuilder();
                int n = 0;
                Calendar cur = (Calendar) now.clone();
                for (int d = 0; d < 8 && n < 5; d++, cur.add(Calendar.DAY_OF_MONTH, 1)) {
                    JSONArray arr = days == null ? null : days.optJSONArray(f.format(cur.getTime()));
                    if (arr == null) continue;
                    if (d == 0 && arr.length() == 0) { sb.append("Hoje\nNada marcado\n"); continue; }
                    if (arr.length() == 0) continue;
                    sb.append(d == 0 ? "Hoje" : d == 1 ? "Amanhã" : lf.format(cur.getTime())).append("\n");
                    for (int i = 0; i < arr.length() && n < 5; i++, n++) sb.append("• ").append(arr.optString(i)).append("\n");
                }
                if (days != null && days.has(f.format(now.getTime()))) agenda = sb.toString().trim();
            }
        } catch (Exception e) {
            agenda = "Abra o Atelas para atualizar.";
        }

        for (int i = 0; i < 42; i++) {
            int cid = c.getResources().getIdentifier("cal_" + i, "id", c.getPackageName());
            if (cid == 0) continue;
            int dd = i - offset + 1;
            if (dd < 1 || dd > total) {
                rv.setTextViewText(cid, "");
                rv.setInt(cid, "setBackgroundResource", 0);
                continue;
            }
            rv.setTextViewText(cid, String.valueOf(dd));
            if (dd == today) {
                rv.setTextColor(cid, 0xFF000000);
                rv.setInt(cid, "setBackgroundResource", R.drawable.widget_today);
            } else {
                rv.setTextColor(cid, mark[dd] ? 0xFF7CC4FF : 0xFFE6E6E6);
                rv.setInt(cid, "setBackgroundResource", mark[dd] ? R.drawable.widget_mark : 0);
            }
        }
        rv.setTextViewText(R.id.cal_agenda, agenda);
        rv.setOnClickPendingIntent(R.id.cal_root, AtelasWidgets.open(c, "cal", 20));
        mgr.updateAppWidget(id, rv);
    }
}
EOF

cat > "$JAVA/AtelasHealthWidget.java" <<'EOF'
package app.atelas.client;

import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.Context;
import android.widget.RemoteViews;
import org.json.JSONObject;

public class AtelasHealthWidget extends AppWidgetProvider {
    @Override
    public void onUpdate(Context context, AppWidgetManager mgr, int[] ids) {
        for (int id : ids) render(context, mgr, id);
    }

    static void render(Context c, AppWidgetManager mgr, int id) {
        RemoteViews rv = new RemoteViews(c.getPackageName(), R.layout.atelas_health_widget);
        int w = 0, wg = 2000, k = 0, kg = 2000;
        boolean ok = false;
        try {
            JSONObject d = AtelasWidgets.data(c);
            JSONObject h = d == null ? null : d.optJSONObject("health");
            if (h != null) {
                ok = true;
                w = h.optInt("water", 0);
                wg = h.optInt("waterGoal", 2000);
                k = h.optInt("kcal", 0);
                kg = h.optInt("kcalGoal", 2000);
            }
        } catch (Exception e) {
            ok = false;
        }
        rv.setTextViewText(R.id.hw_water_t, "Água  " + AtelasWidgets.liters(w) + " / " + AtelasWidgets.liters(wg));
        rv.setProgressBar(R.id.hw_water_p, 100, AtelasWidgets.pct(w, wg), false);
        rv.setTextViewText(R.id.hw_food_t, "Comida  " + k + " / " + kg + " kcal");
        rv.setProgressBar(R.id.hw_food_p, 100, AtelasWidgets.pct(k, kg), false);
        rv.setTextViewText(R.id.hw_hint, ok ? "Toque para registrar" : "Abra o Atelas");
        rv.setOnClickPendingIntent(R.id.hw_root, AtelasWidgets.open(c, "health", 30));
        mgr.updateAppWidget(id, rv);
    }
}
EOF

cat > "$JAVA/AtelasSleepWidget.java" <<'EOF'
package app.atelas.client;

import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.Context;
import android.widget.RemoteViews;
import org.json.JSONObject;

public class AtelasSleepWidget extends AppWidgetProvider {
    @Override
    public void onUpdate(Context context, AppWidgetManager mgr, int[] ids) {
        for (int id : ids) render(context, mgr, id);
    }

    static void render(Context c, AppWidgetManager mgr, int id) {
        RemoteViews rv = new RemoteViews(c.getPackageName(), R.layout.atelas_sleep_widget);
        int min = 0, goal = 480, q = 0;
        try {
            JSONObject d = AtelasWidgets.data(c);
            JSONObject s = d == null ? null : d.optJSONObject("sleep");
            if (s != null) {
                min = s.optInt("min", 0);
                goal = s.optInt("goal", 480);
                q = s.optInt("q", 0);
            }
        } catch (Exception e) {
            min = 0;
        }
        StringBuilder stars = new StringBuilder();
        for (int i = 1; i <= 5; i++) stars.append(i <= q ? "★" : "☆");
        rv.setTextViewText(R.id.sw_main, min > 0 ? AtelasWidgets.hours(min) : "--");
        rv.setTextViewText(R.id.sw_sub, "Meta " + AtelasWidgets.hours(goal));
        rv.setTextViewText(R.id.sw_stars, min > 0 ? stars.toString() : "Sem registro");
        rv.setProgressBar(R.id.sw_p, 100, AtelasWidgets.pct(min, goal), false);
        rv.setOnClickPendingIntent(R.id.sw_root, AtelasWidgets.open(c, "health", 40));
        mgr.updateAppWidget(id, rv);
    }
}
EOF

# ---- layouts e recursos (gerados por Python para não repetir 42 células à mão)
python3 - <<'PY'
import os
R = 'android/app/src/main/res/'
NS = 'xmlns:android="http://schemas.android.com/apk/res/android"'
def w(path, s):
    open(R + path, 'w', encoding='utf-8').write(s)

# Hoje (avisos) 4x2
w('layout/atelas_widget.xml', f'''<?xml version="1.0" encoding="utf-8"?>
<LinearLayout {NS}
    android:id="@+id/wg_root" android:layout_width="match_parent" android:layout_height="match_parent"
    android:orientation="vertical" android:padding="14dp" android:background="@drawable/widget_bg">
    <TextView android:id="@+id/wg_title" android:layout_width="match_parent" android:layout_height="wrap_content"
        android:textColor="#FFFFFF" android:textSize="15sp" android:textStyle="bold" android:maxLines="1" />
    <TextView android:id="@+id/wg_body" android:layout_width="match_parent" android:layout_height="0dp"
        android:layout_weight="1" android:layout_marginTop="6dp" android:textColor="#E6E6E6" android:textSize="13sp" android:ellipsize="end" />
    <TextView android:id="@+id/wg_extra" android:layout_width="match_parent" android:layout_height="wrap_content"
        android:textColor="#A0A0A0" android:textSize="12sp" android:maxLines="1" />
</LinearLayout>
''')

# Calendário 4x2: grade do mês à esquerda, agenda à direita
rows = ''
for r in range(6):
    cells = ''.join(f'''
            <TextView android:id="@+id/cal_{r*7+c}" android:layout_width="0dp" android:layout_height="match_parent"
                android:layout_weight="1" android:gravity="center" android:textSize="9sp" android:includeFontPadding="false"
                android:textColor="#E6E6E6" android:maxLines="1" />''' for c in range(7))
    rows += f'''
        <LinearLayout android:layout_width="match_parent" android:layout_height="0dp" android:layout_weight="1" android:orientation="horizontal">{cells}
        </LinearLayout>'''
head = ''.join('''
            <TextView android:layout_width="0dp" android:layout_height="wrap_content" android:layout_weight="1"
                android:gravity="center" android:textSize="8sp" android:includeFontPadding="false" android:textColor="#8A8A8A" android:text="%s" />''' % d for d in 'DSTQQSS')
w('layout/atelas_cal_widget.xml', f'''<?xml version="1.0" encoding="utf-8"?>
<LinearLayout {NS}
    android:id="@+id/cal_root" android:layout_width="match_parent" android:layout_height="match_parent"
    android:orientation="horizontal" android:padding="10dp" android:background="@drawable/widget_bg">
    <LinearLayout android:layout_width="0dp" android:layout_height="match_parent" android:layout_weight="1.15" android:orientation="vertical">
        <TextView android:id="@+id/cal_title" android:layout_width="match_parent" android:layout_height="wrap_content"
            android:textColor="#FFFFFF" android:textSize="12sp" android:textStyle="bold" android:maxLines="1" android:includeFontPadding="false" />
        <LinearLayout android:layout_width="match_parent" android:layout_height="wrap_content" android:layout_marginTop="3dp" android:orientation="horizontal">{head}
        </LinearLayout>{rows}
    </LinearLayout>
    <LinearLayout android:layout_width="0dp" android:layout_height="match_parent" android:layout_weight="1" android:layout_marginStart="10dp" android:orientation="vertical">
        <TextView android:id="@+id/cal_agenda" android:layout_width="match_parent" android:layout_height="match_parent"
            android:textColor="#E6E6E6" android:textSize="11sp" android:ellipsize="end" />
    </LinearLayout>
</LinearLayout>
''')

def bar(i, d):
    return f'''<ProgressBar android:id="@+id/{i}" style="?android:attr/progressBarStyleHorizontal" android:layout_width="match_parent" android:layout_height="6dp"
        android:layout_marginTop="3dp" android:max="100" android:progress="0" android:progressDrawable="@drawable/{d}" />'''

# Saúde 2x2
w('layout/atelas_health_widget.xml', f'''<?xml version="1.0" encoding="utf-8"?>
<LinearLayout {NS}
    android:id="@+id/hw_root" android:layout_width="match_parent" android:layout_height="match_parent"
    android:orientation="vertical" android:padding="12dp" android:background="@drawable/widget_bg">
    <TextView android:layout_width="match_parent" android:layout_height="wrap_content" android:text="Saúde"
        android:textColor="#FFFFFF" android:textSize="14sp" android:textStyle="bold" android:maxLines="1" />
    <TextView android:id="@+id/hw_water_t" android:layout_width="match_parent" android:layout_height="wrap_content" android:layout_marginTop="8dp"
        android:textColor="#E6E6E6" android:textSize="11sp" android:maxLines="1" />
    {bar('hw_water_p', 'widget_progress_blue')}
    <TextView android:id="@+id/hw_food_t" android:layout_width="match_parent" android:layout_height="wrap_content" android:layout_marginTop="8dp"
        android:textColor="#E6E6E6" android:textSize="11sp" android:maxLines="1" />
    {bar('hw_food_p', 'widget_progress_orange')}
    <TextView android:id="@+id/hw_hint" android:layout_width="match_parent" android:layout_height="wrap_content" android:layout_marginTop="auto"
        android:textColor="#8A8A8A" android:textSize="10sp" android:maxLines="1" />
</LinearLayout>
'''.replace(' android:layout_marginTop="auto"', ''))

# Sono 2x2
w('layout/atelas_sleep_widget.xml', f'''<?xml version="1.0" encoding="utf-8"?>
<LinearLayout {NS}
    android:id="@+id/sw_root" android:layout_width="match_parent" android:layout_height="match_parent"
    android:orientation="vertical" android:padding="12dp" android:background="@drawable/widget_bg">
    <TextView android:layout_width="match_parent" android:layout_height="wrap_content" android:text="Sono"
        android:textColor="#FFFFFF" android:textSize="14sp" android:textStyle="bold" android:maxLines="1" />
    <TextView android:id="@+id/sw_main" android:layout_width="match_parent" android:layout_height="wrap_content" android:layout_marginTop="6dp"
        android:textColor="#FFFFFF" android:textSize="28sp" android:textStyle="bold" android:maxLines="1" />
    <TextView android:id="@+id/sw_sub" android:layout_width="match_parent" android:layout_height="wrap_content"
        android:textColor="#A0A0A0" android:textSize="11sp" android:maxLines="1" />
    {bar('sw_p', 'widget_progress_purple')}
    <TextView android:id="@+id/sw_stars" android:layout_width="match_parent" android:layout_height="wrap_content" android:layout_marginTop="6dp"
        android:textColor="#B46BFF" android:textSize="12sp" android:maxLines="1" />
</LinearLayout>
''')

w('drawable/widget_bg.xml', f'''<?xml version="1.0" encoding="utf-8"?>
<shape {NS} android:shape="rectangle">
    <solid android:color="#F2000000" />
    <corners android:radius="22dp" />
    <stroke android:width="1dp" android:color="#33FFFFFF" />
</shape>
''')
w('drawable/widget_mark.xml', f'''<?xml version="1.0" encoding="utf-8"?>
<shape {NS} android:shape="rectangle">
    <solid android:color="#227CC4FF" />
    <stroke android:width="1dp" android:color="#FF7CC4FF" />
    <corners android:radius="99dp" />
</shape>
''')
w('drawable/widget_today.xml', f'''<?xml version="1.0" encoding="utf-8"?>
<shape {NS} android:shape="oval">
    <solid android:color="#FFFFFFFF" />
</shape>
''')
for name, color in [('blue', '#FF4F8CFF'), ('orange', '#FFFFB020'), ('purple', '#FFB46BFF')]:
    w(f'drawable/widget_progress_{name}.xml', f'''<?xml version="1.0" encoding="utf-8"?>
<layer-list {NS}>
    <item android:id="@android:id/background">
        <shape android:shape="rectangle"><solid android:color="#33FFFFFF" /><corners android:radius="3dp" /></shape>
    </item>
    <item android:id="@android:id/progress">
        <clip><shape android:shape="rectangle"><solid android:color="{color}" /><corners android:radius="3dp" /></shape></clip>
    </item>
</layer-list>
''')

def info(name, wd, ht, cw, ch, desc):
    w(f'xml/{name}.xml', f'''<?xml version="1.0" encoding="utf-8"?>
<appwidget-provider {NS}
    android:minWidth="{wd}dp" android:minHeight="{ht}dp"
    android:targetCellWidth="{cw}" android:targetCellHeight="{ch}"
    android:updatePeriodMillis="1800000"
    android:initialLayout="@layout/{name.replace('_info','')}"
    android:resizeMode="horizontal|vertical"
    android:widgetCategory="home_screen"
    android:description="@string/{desc}" />
''')
info('atelas_widget_info', 250, 110, 4, 2, 'widget_desc')
info('atelas_cal_widget_info', 250, 110, 4, 2, 'widget_cal_desc')
info('atelas_health_widget_info', 110, 110, 2, 2, 'widget_health_desc')
info('atelas_sleep_widget_info', 110, 110, 2, 2, 'widget_sleep_desc')

w('values/atelas_widget_strings.xml', '''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="widget_desc">Seus avisos do dia na tela inicial</string>
    <string name="widget_cal_desc">Calendário do mês com a agenda de hoje</string>
    <string name="widget_health_desc">Água e alimentação do dia</string>
    <string name="widget_sleep_desc">Horas dormidas e qualidade do sono</string>
</resources>
''')

# manifesto: receivers dos 4 widgets + microfone
p = 'android/app/src/main/AndroidManifest.xml'
t = open(p, encoding='utf-8').read()
def rec(cls, label, info):
    return f'''
        <receiver android:name=".{cls}" android:label="{label}" android:exported="false">
            <intent-filter>
                <action android:name="android.appwidget.action.APPWIDGET_UPDATE" />
            </intent-filter>
            <meta-data android:name="android.appwidget.provider" android:resource="@xml/{info}" />
        </receiver>'''
recs = (rec('AtelasWidgetProvider', 'Atelas Hoje', 'atelas_widget_info') +
        rec('AtelasCalendarWidget', 'Atelas Calendário', 'atelas_cal_widget_info') +
        rec('AtelasHealthWidget', 'Atelas Saúde', 'atelas_health_widget_info') +
        rec('AtelasSleepWidget', 'Atelas Sono', 'atelas_sleep_widget_info'))
assert t.count('</application>') == 1 and t.count('</manifest>') == 1
t = t.replace('</application>', recs + '\n    </application>', 1)
perms = '''    <uses-permission android:name="android.permission.RECORD_AUDIO" />
    <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
    <uses-feature android:name="android.hardware.microphone" android:required="false" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.USE_EXACT_ALARM" />
    <uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM" android:maxSdkVersion="32" />
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />
    <uses-permission android:name="android.permission.VIBRATE" />
'''
t = t.replace('</manifest>', perms + '</manifest>', 1)
open(p, 'w', encoding='utf-8').write(t)
PY
