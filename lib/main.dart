import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'firebase_options.dart';
import 'secrets.dart';

// =====================================================================
//  共通設定
// =====================================================================

// 通知プラグイン
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

// ポップアップ通知用チャンネル
const AndroidNotificationChannel channel = AndroidNotificationChannel(
  'high_importance_channel',
  '服薬・健康通知',
  description: '重要な服薬時間をお知らせします',
  importance: Importance.max,
);

// AIで使うモデル名（変更しやすいように定数化）
const String geminiModelName = 'gemini-2.5-flash-lite';

// アプリ全体の色
class AppColors {
  static const primary = Color(0xFF0F9D8A);
  static const primaryDark = Color(0xFF0B6E61);
  static const gradientStart = Color(0xFF16B59D);
  static const gradientEnd = Color(0xFF0B7D6E);
  static const accent = Color(0xFFFF8A65);
  static const bg = Color(0xFFF3F6F5);
  static const ink = Color(0xFF14211E);
  static const sub = Color(0xFF6B7A76);
  static const line = Color(0xFFE3EAE8);
  static const danger = Color(0xFFE5484D);
  static const shadow = Color(0x140B3B33);
}

// 通知の見た目（予約通知・テスト通知で共通）
NotificationDetails notificationDetails() => NotificationDetails(
  android: AndroidNotificationDetails(
    channel.id,
    channel.name,
    channelDescription: channel.description,
    importance: Importance.max,
    priority: Priority.high,
  ),
  iOS: const DarwinNotificationDetails(),
);

AndroidFlutterLocalNotificationsPlugin? get androidNotificationPlugin =>
    flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();

// 正確なアラームが使えなければ、多少ずれても届くモードにフォールバック
Future<AndroidScheduleMode> resolveScheduleMode() async {
  final android = androidNotificationPlugin;
  if (android == null) return AndroidScheduleMode.exactAllowWhileIdle;
  final canExact = await android.canScheduleExactNotifications() ?? false;
  return canExact
      ? AndroidScheduleMode.exactAllowWhileIdle
      : AndroidScheduleMode.inexactAllowWhileIdle;
}

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
String dayKey(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

// 服薬時間 → 朝・昼・夕方・夜
class DosePeriod {
  final String label;
  final IconData icon;
  final Color color;
  const DosePeriod(this.label, this.icon, this.color);
}

DosePeriod periodOf(String time) {
  final h = int.tryParse(time.split(':').first) ?? 0;
  if (h >= 4 && h < 11) {
    return const DosePeriod('朝', Icons.wb_sunny_rounded, Color(0xFFF5A623));
  }
  if (h >= 11 && h < 15) {
    return const DosePeriod('昼', Icons.light_mode_rounded, Color(0xFFEF7D3C));
  }
  if (h >= 15 && h < 19) {
    return const DosePeriod('夕方', Icons.wb_twilight, Color(0xFFE0607E));
  }
  return const DosePeriod('夜', Icons.nightlight_round, Color(0xFF5B6CD9));
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // 日付を日本語で表示（「10月14日 水曜日」など）
  await initializeDateFormatting('ja_JP');
  Intl.defaultLocale = 'ja_JP';

  tz.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation('Asia/Tokyo'));

  const InitializationSettings initializationSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(),
  );
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);
  await androidNotificationPlugin?.createNotificationChannel(channel);

  runApp(const HealthBuddyApp());
}

class HealthBuddyApp extends StatelessWidget {
  const HealthBuddyApp({super.key});
  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      primary: AppColors.primary,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'my_health_app',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: AppColors.bg,
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.bg,
          foregroundColor: AppColors.ink,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          height: 68,
          indicatorColor: const Color(0xFFD6F1EC),
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
              fontSize: 12,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w800
                  : FontWeight.w500,
              color: states.contains(WidgetState.selected)
                  ? AppColors.primaryDark
                  : AppColors.sub,
            ),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
      ),
      home: const MainNavigationScreen(),
    );
  }
}

// =====================================================================
//  共通ウィジェット
// =====================================================================

// 白い角丸カード
class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;
  final VoidCallback? onTap;
  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.color = Colors.white,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [
          BoxShadow(
            color: AppColors.shadow,
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  const SectionTitle(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 17,
      fontWeight: FontWeight.w800,
      color: AppColors.ink,
    ),
  );
}

class IconBubble extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  const IconBubble(this.icon, this.color, {super.key, this.size = 42});
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color.withAlpha(32),
      shape: BoxShape.circle,
    ),
    child: Icon(icon, color: color, size: size * 0.52),
  );
}

class GradientCircle extends StatelessWidget {
  final IconData icon;
  final double size;
  const GradientCircle(this.icon, {super.key, this.size = 44});
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      gradient: LinearGradient(
        colors: [AppColors.gradientStart, AppColors.gradientEnd],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    child: Icon(icon, color: Colors.white, size: size * 0.5),
  );
}

// =====================================================================
//  メイン画面（下のタブ）
// =====================================================================

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});
  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  final String myId = "user_001";
  List<String> _medicationTimes = [];
  bool _isNotificationOn = true;
  // 設定を読み込み終えるまで各画面を作らない
  bool _settingsLoaded = false;
  final GlobalKey<_MapPageState> _mapKey = GlobalKey<_MapPageState>();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _loadSettings();
    await _requestPermissions();
    // ブラウザ版は通知の予約に対応していないのでスキップ
    if (!kIsWeb) {
      if (_isNotificationOn) {
        await _scheduleAllNotifications();
      } else {
        await flutterLocalNotificationsPlugin.cancelAll();
      }
    }
  }

  // 位置情報の許可は、地図タブを開いたときに求める
  Future<void> _requestPermissions() async {
    final android = androidNotificationPlugin;
    if (android != null) {
      await android.requestNotificationsPermission();
      // 未許可のときだけ設定画面を開く（毎回開かないように）
      final canExact = await android.canScheduleExactNotifications() ?? false;
      if (!canExact) await android.requestExactAlarmsPermission();
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final times =
        (prefs.getStringList('med_times') ?? ["08:00", "19:00"])
            .toSet()
            .toList()
          ..sort();
    if (!mounted) return;
    setState(() {
      _medicationTimes = times;
      _isNotificationOn = prefs.getBool('notif_on') ?? true;
      _settingsLoaded = true;
    });
  }

  // 結果メッセージを返し、設定画面でスナックバー表示する
  Future<String> _saveSettings(List<String> times, bool notif) async {
    final sorted = times.toSet().toList()..sort();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('med_times', sorted);
    await prefs.setBool('notif_on', notif);
    setState(() {
      _medicationTimes = sorted;
      _isNotificationOn = notif;
    });
    if (kIsWeb) {
      return "保存しました（ブラウザ版では通知は届きません）";
    }
    if (!notif) {
      await flutterLocalNotificationsPlugin.cancelAll();
      return "保存しました（通知はオフです）";
    }
    return _scheduleAllNotifications();
  }

  Future<String> _scheduleAllNotifications() async {
    try {
      await flutterLocalNotificationsPlugin.cancelAll();
      final mode = await resolveScheduleMode();
      for (int i = 0; i < _medicationTimes.length; i++) {
        final t = _medicationTimes[i];
        final parts = t.split(':');
        final total = int.parse(parts[0]) * 60 + int.parse(parts[1]);
        final before = (total - 5) % (24 * 60); // 0:03 → 23:58 も正しく計算
        await _schedule(
          i * 2,
          "💊 服薬5分前です",
          "$t の服薬まであと5分です。準備をしましょう",
          before ~/ 60,
          before % 60,
          mode,
        );
        await _schedule(
          i * 2 + 1,
          "⏰ お薬の時間です",
          "$t の薬を飲んで、記録をつけましょう",
          total ~/ 60,
          total % 60,
          mode,
        );
      }
      final count = _medicationTimes.length * 2;
      if (mode == AndroidScheduleMode.exactAllowWhileIdle) {
        return "保存しました（通知 $count 件を予約）";
      }
      return "保存しました（通知 $count 件を予約。「アラームとリマインダー」が未許可のため、数分ずれることがあります）";
    } catch (e) {
      debugPrint("通知の予約に失敗: $e");
      return "通知の予約に失敗しました: $e";
    }
  }

  Future<void> _schedule(
    int id,
    String title,
    String body,
    int h,
    int m,
    AndroidScheduleMode mode,
  ) {
    return flutterLocalNotificationsPlugin.zonedSchedule(
      id,
      title,
      body,
      _nextInstance(h, m),
      notificationDetails(),
      androidScheduleMode: mode,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: DateTimeComponents.time, // 毎日くり返し
    );
  }

  tz.TZDateTime _nextInstance(int h, int m) {
    final now = tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime(tz.local, now.year, now.month, now.day, h, m);
    if (!scheduled.isAfter(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }

  @override
  Widget build(BuildContext context) {
    if (!_settingsLoaded) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GradientCircle(Icons.medication_rounded, size: 84),
              SizedBox(height: 24),
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            ],
          ),
        ),
      );
    }
    final List<Widget> pages = [
      MedicationCalendarPage(userId: myId, activeTimings: _medicationTimes),
      AIChatPage(userId: myId),
      MapPage(key: _mapKey),
      SettingsPage(
        initialTimes: _medicationTimes,
        initialNotif: _isNotificationOn,
        onSave: _saveSettings,
      ),
    ];
    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: pages),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: Color(0x120B3B33),
              blurRadius: 20,
              offset: Offset(0, -4),
            ),
          ],
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (i) {
            setState(() => _currentIndex = i);
            // 地図タブを初めて開いたときに周辺の医療機関を読み込む
            if (i == 2) _mapKey.currentState?.onShown();
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.today_outlined),
              selectedIcon: Icon(Icons.today),
              label: "今日",
            ),
            NavigationDestination(
              icon: Icon(Icons.auto_awesome_outlined),
              selectedIcon: Icon(Icons.auto_awesome),
              label: "AI栄養",
            ),
            NavigationDestination(
              icon: Icon(Icons.map_outlined),
              selectedIcon: Icon(Icons.map),
              label: "病院マップ",
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: "設定",
            ),
          ],
        ),
      ),
    );
  }
}

// =====================================================================
//  1. 今日の服薬（はなまるカレンダー）
// =====================================================================

class MedicationCalendarPage extends StatefulWidget {
  final String userId;
  final List<String> activeTimings;
  const MedicationCalendarPage({
    required this.userId,
    required this.activeTimings,
    super.key,
  });
  @override
  State<MedicationCalendarPage> createState() => _MedicationCalendarPageState();
}

class _MedicationCalendarPageState extends State<MedicationCalendarPage> {
  DateTime _selectedDay = dateOnly(DateTime.now());
  DateTime _focusedDay = DateTime.now();
  // ストリームは1本だけ作って使い回す
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _logsStream;

  CollectionReference<Map<String, dynamic>> get _logsRef => FirebaseFirestore
      .instance
      .collection('users')
      .doc(widget.userId)
      .collection('med_logs');

  @override
  void initState() {
    super.initState();
    _logsStream = _logsRef.snapshots();
  }

  bool _isPast(DateTime d) => dateOnly(d).isBefore(dateOnly(DateTime.now()));
  bool _isFuture(DateTime d) => dateOnly(d).isAfter(dateOnly(DateTime.now()));

  // 過去の日は「その日に記録したときの服薬時間」で判定する
  List<String> _timingsFor(DateTime day, Map<String, dynamic>? log) {
    final saved = log?['_timings'];
    if (_isPast(day) && saved is List && saved.isNotEmpty) {
      return saved.map((e) => e.toString()).toList();
    }
    return widget.activeTimings;
  }

  bool _isAllDone(DateTime day, Map<String, dynamic>? log) {
    if (log == null) return false;
    final timings = _timingsFor(day, log);
    return timings.isNotEmpty && timings.every((t) => log[t] == true);
  }

  // 連続達成日数（今日が未完了でも、昨日までの連続はキープ）
  int _streak(Map<String, Map<String, dynamic>> logs) {
    var day = dateOnly(DateTime.now());
    if (!_isAllDone(day, logs[dayKey(day)])) {
      day = DateTime(day.year, day.month, day.day - 1);
    }
    var count = 0;
    while (count < 3650 && _isAllDone(day, logs[dayKey(day)])) {
      count++;
      day = DateTime(day.year, day.month, day.day - 1);
    }
    return count;
  }

  int _monthDone(Map<String, Map<String, dynamic>> logs) {
    final y = _focusedDay.year;
    final m = _focusedDay.month;
    final days = DateTime(y, m + 1, 0).day;
    var c = 0;
    for (var i = 1; i <= days; i++) {
      final d = DateTime(y, m, i);
      if (_isAllDone(d, logs[dayKey(d)])) c++;
    }
    return c;
  }

  Future<void> _toggle(
    String timing,
    List<String> timings,
    Map<String, Map<String, dynamic>> logs,
  ) async {
    final key = dayKey(_selectedDay);
    final current = logs[key]?[timing] == true;
    final value = !current;
    final updated = <String, dynamic>{
      ...?logs[key],
      timing: value,
      '_timings': timings,
    };
    final willComplete = value && timings.every((t) => updated[t] == true);
    HapticFeedback.lightImpact();
    try {
      final write = _logsRef.doc(key).set({
        timing: value,
        '_timings': timings,
      }, SetOptions(merge: true));
      if (willComplete) {
        final newLogs = Map<String, Map<String, dynamic>>.from(logs)
          ..[key] = updated;
        _celebrate(
          _streak(newLogs),
          isToday: isSameDay(_selectedDay, DateTime.now()),
        );
      }
      await write;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("記録の保存に失敗しました: $e")));
    }
  }

  // 全部飲み終えたときのお祝い演出
  void _celebrate(int streak, {required bool isToday}) {
    HapticFeedback.mediumImpact();
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '閉じる',
      barrierColor: const Color(0xAA000000),
      transitionDuration: const Duration(milliseconds: 550),
      pageBuilder: (ctx, a1, a2) => GestureDetector(
        onTap: () => Navigator.of(ctx).pop(),
        child: Material(
          type: MaterialType.transparency,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('💮', style: TextStyle(fontSize: 120)),
                const SizedBox(height: 8),
                Text(
                  isToday ? '今日の服薬、ぜんぶ完了！' : 'この日の服薬、ぜんぶ完了！',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  streak >= 2 ? '$streak日連続で達成中 🔥' : 'この調子で続けていきましょう',
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
                const SizedBox(height: 28),
                const Text(
                  'タップして閉じる',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
      transitionBuilder: (ctx, anim, a2, child) => FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          scale: CurvedAnimation(
            parent: anim,
            curve: Curves.elasticOut,
            reverseCurve: Curves.easeIn,
          ),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _logsStream,
          builder: (context, snapshot) {
            if (snapshot.hasError) return _errorView(snapshot.error);
            final logs = <String, Map<String, dynamic>>{
              for (final doc
                  in snapshot.data?.docs ??
                      const <QueryDocumentSnapshot<Map<String, dynamic>>>[])
                doc.id: doc.data(),
            };
            final isToday = isSameDay(_selectedDay, DateTime.now());
            final selectedLog = logs[dayKey(_selectedDay)];
            final timings = _timingsFor(_selectedDay, selectedLog);
            final isFuture = _isFuture(_selectedDay);
            final done = timings.where((t) => selectedLog?[t] == true).length;
            final streak = _streak(logs);

            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: [
                _header(streak),
                const SizedBox(height: 18),
                _progressCard(
                  done: done,
                  timings: timings,
                  log: selectedLog,
                  isToday: isToday,
                  isFuture: isFuture,
                ),
                const SizedBox(height: 26),
                SectionTitle(
                  isToday
                      ? '今日のお薬'
                      : '${DateFormat('M月d日(E)').format(_selectedDay)}のお薬',
                ),
                const SizedBox(height: 10),
                if (timings.isEmpty)
                  const Panel(
                    child: Row(
                      children: [
                        IconBubble(Icons.add_alarm_rounded, AppColors.primary),
                        SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            '設定タブから服薬時間を追加すると、ここに表示されます',
                            style: TextStyle(color: AppColors.sub),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  ...timings.map(
                    (t) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: DoseTile(
                        time: t,
                        done: selectedLog?[t] == true,
                        enabled: !isFuture,
                        onTap: () => _toggle(t, timings, logs),
                      ),
                    ),
                  ),
                if (isFuture)
                  const Padding(
                    padding: EdgeInsets.only(top: 2, left: 4),
                    child: Text(
                      '未来の日付は、当日になってから記録できます',
                      style: TextStyle(fontSize: 12, color: AppColors.sub),
                    ),
                  ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    const SectionTitle('カレンダー'),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFEFE9),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${_focusedDay.month}月の達成 ${_monthDone(logs)}日 💮',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFD9534F),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Panel(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                  child: _calendar(logs),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _errorView(Object? error) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Panel(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const IconBubble(
              Icons.cloud_off_rounded,
              AppColors.danger,
              size: 56,
            ),
            const SizedBox(height: 14),
            const Text(
              '記録を読み込めませんでした',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text(
              'Firestoreのセキュリティルール（テストモードの期限切れなど）を確認してください。',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.sub),
            ),
            const SizedBox(height: 10),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: AppColors.sub),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _header(int streak) {
    final now = DateTime.now();
    final h = now.hour;
    final greet = h < 4
        ? 'こんばんは'
        : h < 11
        ? 'おはようございます'
        : h < 18
        ? 'こんにちは'
        : 'こんばんは';
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                DateFormat('M月d日 EEEE').format(now),
                style: const TextStyle(
                  color: AppColors.sub,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                greet,
                style: const TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.w800,
                  color: AppColors.ink,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            gradient: streak > 0
                ? const LinearGradient(
                    colors: [Color(0xFFFFB25B), Color(0xFFFF7A59)],
                  )
                : null,
            color: streak > 0 ? null : Colors.white,
            borderRadius: BorderRadius.circular(22),
            boxShadow: const [
              BoxShadow(
                color: AppColors.shadow,
                blurRadius: 14,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Text(
            streak > 0 ? '🔥 $streak日連続' : '🌱 今日から',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: streak > 0 ? Colors.white : AppColors.primaryDark,
            ),
          ),
        ),
      ],
    );
  }

  Widget _progressCard({
    required int done,
    required List<String> timings,
    required Map<String, dynamic>? log,
    required bool isToday,
    required bool isFuture,
  }) {
    final total = timings.length;
    String title;
    String sub;
    if (total == 0) {
      title = '時間が未設定です';
      sub = '設定タブから服薬時間を追加しましょう';
    } else if (isFuture) {
      title = 'まだ先の日です';
      sub = '当日になったら記録できます';
    } else if (done == total) {
      title = 'ぜんぶ完了 💮';
      sub = isToday ? 'えらい！この調子で続けましょう' : 'この日は達成しています';
    } else if (isToday) {
      final next = timings.firstWhere((t) => log?[t] != true);
      final parts = next.split(':');
      final now = DateTime.now();
      final at = DateTime(
        now.year,
        now.month,
        now.day,
        int.parse(parts[0]),
        int.parse(parts[1]),
      );
      if (at.isAfter(now)) {
        final diff = at.difference(now);
        final hh = diff.inHours;
        final mm = diff.inMinutes % 60;
        title = '次は $next';
        sub = hh > 0 ? 'あと$hh時間$mm分' : 'あと$mm分';
      } else {
        title = '$next の分が未記録';
        sub = '飲んだらタップして記録しましょう';
      }
    } else {
      title = '${total - done}回分が未記録';
      sub = '飲んでいたら、下のリストから記録できます';
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.gradientStart, AppColors.gradientEnd],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: const [
          BoxShadow(
            color: Color(0x400F9D8A),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          ProgressRing(done: done, total: total),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isToday
                      ? '今日の服薬'
                      : '${DateFormat('M月d日(E)').format(_selectedDay)}の服薬',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  sub,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
                if (!isToday) ...[
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () => setState(() {
                      _selectedDay = dateOnly(DateTime.now());
                      _focusedDay = DateTime.now();
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0x33FFFFFF),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Text(
                        '今日に戻る',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _calendar(Map<String, Map<String, dynamic>> logs) {
    return TableCalendar(
      locale: 'ja_JP',
      focusedDay: _focusedDay,
      firstDay: DateTime.utc(2024, 1, 1),
      lastDay: DateTime.utc(2030, 12, 31),
      startingDayOfWeek: StartingDayOfWeek.sunday,
      availableCalendarFormats: const {CalendarFormat.month: '月'},
      rowHeight: 46,
      selectedDayPredicate: (d) => isSameDay(_selectedDay, d),
      onDaySelected: (selected, focused) => setState(() {
        _selectedDay = dateOnly(selected);
        _focusedDay = focused;
      }),
      onPageChanged: (focused) => setState(() => _focusedDay = focused),
      headerStyle: const HeaderStyle(
        formatButtonVisible: false,
        titleCentered: true,
        titleTextStyle: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: AppColors.ink,
        ),
        leftChevronIcon: Icon(Icons.chevron_left_rounded, color: AppColors.ink),
        rightChevronIcon: Icon(
          Icons.chevron_right_rounded,
          color: AppColors.ink,
        ),
      ),
      daysOfWeekStyle: const DaysOfWeekStyle(
        weekdayStyle: TextStyle(
          color: AppColors.sub,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        weekendStyle: TextStyle(
          color: AppColors.danger,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      calendarStyle: const CalendarStyle(
        outsideDaysVisible: false,
        cellMargin: EdgeInsets.all(5),
        defaultTextStyle: TextStyle(
          color: AppColors.ink,
          fontWeight: FontWeight.w600,
        ),
        weekendTextStyle: TextStyle(
          color: AppColors.danger,
          fontWeight: FontWeight.w600,
        ),
        todayDecoration: BoxDecoration(
          color: Color(0xFFD6F1EC),
          shape: BoxShape.circle,
        ),
        todayTextStyle: TextStyle(
          color: AppColors.primaryDark,
          fontWeight: FontWeight.w800,
        ),
        selectedDecoration: BoxDecoration(
          color: AppColors.primary,
          shape: BoxShape.circle,
        ),
        selectedTextStyle: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
        ),
      ),
      calendarBuilders: CalendarBuilders(
        markerBuilder: (context, date, events) {
          final log = logs[dayKey(date)];
          if (_isAllDone(date, log)) {
            return const Positioned(
              bottom: -2,
              child: Text("💮", style: TextStyle(fontSize: 13)),
            );
          }
          // 一部だけ飲んだ日は小さな点
          if (log != null &&
              _timingsFor(date, log).any((t) => log[t] == true)) {
            return Positioned(
              bottom: 3,
              child: Container(
                width: 5,
                height: 5,
                decoration: const BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                ),
              ),
            );
          }
          return null;
        },
      ),
    );
  }
}

class ProgressRing extends StatelessWidget {
  final int done;
  final int total;
  const ProgressRing({super.key, required this.done, required this.total});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 92,
      height: 92,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: total == 0 ? 0 : done / total),
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeOutCubic,
        builder: (context, value, _) => Stack(
          alignment: Alignment.center,
          children: [
            SizedBox.expand(
              child: CircularProgressIndicator(
                value: value,
                strokeWidth: 9,
                strokeCap: StrokeCap.round,
                backgroundColor: const Color(0x33FFFFFF),
                valueColor: const AlwaysStoppedAnimation(Colors.white),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$done',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                  ),
                ),
                Text(
                  '/ $total回',
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class DoseTile extends StatelessWidget {
  final String time;
  final bool done;
  final bool enabled;
  final VoidCallback onTap;
  const DoseTile({
    super.key,
    required this.time,
    required this.done,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = periodOf(time);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      decoration: BoxDecoration(
        color: done ? const Color(0xFFE6F6F3) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: done ? const Color(0xFF9FDCCF) : Colors.transparent,
          width: 1.5,
        ),
        boxShadow: done
            ? const []
            : const [
                BoxShadow(
                  color: AppColors.shadow,
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                IconBubble(p.icon, p.color, size: 46),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        time,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: AppColors.ink,
                        ),
                      ),
                      Text(
                        done ? '${p.label}のお薬・服用済み' : '${p.label}のお薬・タップで記録',
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.sub,
                        ),
                      ),
                    ],
                  ),
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  transitionBuilder: (child, anim) =>
                      ScaleTransition(scale: anim, child: child),
                  child: done
                      ? const Icon(
                          Icons.check_circle_rounded,
                          key: ValueKey('done'),
                          color: AppColors.primary,
                          size: 36,
                        )
                      : Icon(
                          Icons.radio_button_unchecked_rounded,
                          key: const ValueKey('todo'),
                          color: enabled
                              ? const Color(0xFFB8C6C2)
                              : const Color(0xFFDDE3E1),
                          size: 36,
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
//  2. AI栄養アドバイザー
// =====================================================================

class ChatMessage {
  final bool fromUser;
  final String text;
  final bool isError;
  const ChatMessage(this.text, {required this.fromUser, this.isError = false});
}

class AIChatPage extends StatefulWidget {
  final String userId;
  const AIChatPage({required this.userId, super.key});
  @override
  State<AIChatPage> createState() => _AIChatPageState();
}

class _AIChatPageState extends State<AIChatPage> {
  final _c = TextEditingController();
  final _scroll = ScrollController();
  final List<ChatMessage> _m = [];
  bool _l = false;
  late final GenerativeModel _model = GenerativeModel(
    model: geminiModelName,
    apiKey: geminiApiKey,
  );

  static const _samples = [
    '朝はトーストとコーヒーだけ',
    '昼にラーメンと餃子を食べた',
    '夜はコンビニのサラダとおにぎり',
    '最近お菓子を食べすぎている',
  ];

  @override
  void dispose() {
    _c.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  // Gemini の Markdown 記号を読みやすく整える
  String _clean(String s) => s
      .replaceAll('**', '')
      .replaceAll(RegExp(r'^#+\s*', multiLine: true), '')
      .replaceAll(RegExp(r'^\s*[\*\-]\s+', multiLine: true), '・')
      .trim();

  Future<void> _send(String raw) async {
    final text = raw.trim();
    if (text.isEmpty || _l) return;
    setState(() {
      _m.add(ChatMessage(text, fromUser: true));
      _l = true;
    });
    _c.clear();
    _scrollToEnd();
    try {
      final res = await _model.generateContent([
        Content.text(
          "あなたは管理栄養士です。ユーザーが食べた内容について、日本語でやさしく200字程度で助言してください。"
          "「良いところ」「気をつけたいところ」「次の食事のおすすめ」の順に短くまとめてください。"
          "服薬中の人も使うアプリなので、薬との飲み合わせなど医療的な判断が必要な内容は医師・薬剤師への相談を勧めてください。\n"
          "食事内容: $text",
        ),
      ]);
      if (!mounted) return;
      setState(
        () => _m.add(
          ChatMessage(_clean(res.text ?? '（回答が空でした）'), fromUser: false),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _m.add(
          ChatMessage('うまく回答できませんでした。\n$e', fromUser: false, isError: true),
        ),
      );
    } finally {
      if (mounted) setState(() => _l = false);
      _scrollToEnd();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        titleSpacing: 20,
        title: const Row(
          children: [
            GradientCircle(Icons.auto_awesome, size: 42),
            SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AI栄養アドバイザー',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                Text(
                  '食べたものを送るとアドバイスします',
                  style: TextStyle(fontSize: 12, color: AppColors.sub),
                ),
              ],
            ),
          ],
        ),
        actions: [
          if (_m.isNotEmpty)
            IconButton(
              tooltip: '会話をクリア',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _l ? null : () => setState(_m.clear),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _m.isEmpty
                ? _emptyState()
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: _m.length + (_l ? 1 : 0),
                    itemBuilder: (ctx, i) =>
                        i >= _m.length ? _typingBubble() : _bubble(_m[i]),
                  ),
          ),
          _inputBar(),
        ],
      ),
    );
  }

  Widget _emptyState() => ListView(
    padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
    children: [
      const Center(child: GradientCircle(Icons.restaurant_rounded, size: 84)),
      const SizedBox(height: 20),
      const Text(
        '今日は何を食べましたか？',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 8),
      const Text(
        '食べたものを送ると、AIが栄養バランスについて\nアドバイスします',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppColors.sub, height: 1.5),
      ),
      const SizedBox(height: 24),
      Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: _samples
            .map(
              (s) => ActionChip(
                label: Text(s),
                onPressed: () => _send(s),
                backgroundColor: Colors.white,
                side: const BorderSide(color: AppColors.line),
                shape: const StadiumBorder(),
              ),
            )
            .toList(),
      ),
      const SizedBox(height: 28),
      const Text(
        '※ AIの助言は参考情報です。治療中の方は医師・薬剤師の指示を優先してください。',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, color: AppColors.sub),
      ),
    ],
  );

  Widget _bubble(ChatMessage msg) {
    final user = msg.fromUser;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: user
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!user) ...[
            const GradientCircle(Icons.auto_awesome, size: 32),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                gradient: user
                    ? const LinearGradient(
                        colors: [
                          AppColors.gradientStart,
                          AppColors.gradientEnd,
                        ],
                      )
                    : null,
                color: user
                    ? null
                    : (msg.isError ? const Color(0xFFFFEEEE) : Colors.white),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(20),
                  topRight: const Radius.circular(20),
                  bottomLeft: Radius.circular(user ? 20 : 6),
                  bottomRight: Radius.circular(user ? 6 : 20),
                ),
                boxShadow: user
                    ? const []
                    : const [
                        BoxShadow(
                          color: AppColors.shadow,
                          blurRadius: 14,
                          offset: Offset(0, 4),
                        ),
                      ],
              ),
              child: SelectableText(
                msg.text,
                style: TextStyle(
                  color: user ? Colors.white : AppColors.ink,
                  fontSize: 15,
                  height: 1.6,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _typingBubble() => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      children: [
        const GradientCircle(Icons.auto_awesome, size: 32),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              Text('考え中…', style: TextStyle(color: AppColors.sub)),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _inputBar() => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(28),
                boxShadow: const [
                  BoxShadow(
                    color: AppColors.shadow,
                    blurRadius: 16,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: TextField(
                controller: _c,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: _send,
                decoration: const InputDecoration(
                  hintText: '食べたものを入力（例：牛丼と味噌汁）',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Opacity(
            opacity: _l ? 0.5 : 1,
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: _l ? null : () => _send(_c.text),
                child: const GradientCircle(
                  Icons.arrow_upward_rounded,
                  size: 50,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

// =====================================================================
//  3. 病院マップ
// =====================================================================

// ひらがな・カタカナ・全角/半角・空白の違いを吸収して比較する
String normalizeJa(String s) {
  final b = StringBuffer();
  for (final r in s.toLowerCase().runes) {
    var c = r;
    if (c >= 0x30A1 && c <= 0x30F6) c -= 0x60; // カタカナ → ひらがな
    if (c >= 0xFF01 && c <= 0xFF5E) c -= 0xFEE0; // 全角英数 → 半角
    if (c >= 0x41 && c <= 0x5A) c += 0x20; // 大文字 → 小文字
    if (c == 0x20 || c == 0x3000 || c == 0x30FB) continue; // 空白・中黒
    b.writeCharCode(c);
  }
  return b.toString();
}

enum FacilityCategory {
  hospital('病院', Icons.local_hospital_rounded, Color(0xFFE5484D)),
  clinic('クリニック', Icons.medical_services_rounded, Color(0xFF0F9D8A)),
  dentist('歯科', Icons.sentiment_satisfied_alt_rounded, Color(0xFF8E4EC6)),
  pharmacy('薬局', Icons.local_pharmacy_rounded, Color(0xFFF76B15)),
  other('医療施設', Icons.healing_rounded, Color(0xFF5B6B77));

  const FacilityCategory(this.label, this.icon, this.color);
  final String label;
  final IconData icon;
  final Color color;

  static FacilityCategory fromTags(Map<String, dynamic> t) {
    final a = (t['amenity'] ?? '').toString();
    final h = (t['healthcare'] ?? '').toString();
    if (a == 'hospital' || h == 'hospital') return hospital;
    if (a == 'dentist' || h == 'dentist') return dentist;
    if (a == 'pharmacy' || h == 'pharmacy') return pharmacy;
    if (a == 'clinic' || a == 'doctors' || h == 'clinic' || h == 'doctor') {
      return clinic;
    }
    return other;
  }

  static FacilityCategory byName(String? n) => FacilityCategory.values
      .firstWhere((c) => c.name == n, orElse: () => FacilityCategory.other);
}

// 診療科・種類のキーワード（読みがなで部分入力しても候補に出る）
class MedKeyword {
  final String label;
  final List<String> readings;
  final List<String> aliases;
  final FacilityCategory? category;
  const MedKeyword(
    this.label,
    this.readings, {
    this.aliases = const [],
    this.category,
  });

  IconData get icon => category?.icon ?? Icons.medical_information_rounded;
  Color get color => category?.color ?? AppColors.primaryDark;

  bool matches(Facility f) => category != null
      ? f.category == category
      : f.specialities.contains(label);

  bool matchesQuery(String n) {
    if (n.isEmpty) return false;
    final l = normalizeJa(label);
    return l.contains(n) ||
        n.contains(l) ||
        readings.any((r) => normalizeJa(r).startsWith(n)) ||
        aliases.any((a) => normalizeJa(a).contains(n));
  }

  bool exactly(String n) =>
      normalizeJa(label) == n ||
      readings.any((r) => normalizeJa(r) == n) ||
      aliases.any((a) => normalizeJa(a) == n);
}

const List<MedKeyword> medKeywords = [
  MedKeyword('内科', ['ないか']),
  MedKeyword('皮膚科', ['ひふか', 'ひふ'], aliases: ['皮フ科', 'ひふ科']),
  MedKeyword(
    '歯科',
    ['しか', 'はいしゃ'],
    aliases: ['歯医者', 'デンタル'],
    category: FacilityCategory.dentist,
  ),
  MedKeyword(
    '薬局',
    ['やっきょく', 'くすり', 'どらっぐ'],
    aliases: ['ドラッグ', '調剤'],
    category: FacilityCategory.pharmacy,
  ),
  MedKeyword('眼科', ['がんか', 'めいしゃ'], aliases: ['目医者', 'アイクリニック']),
  MedKeyword('耳鼻咽喉科', ['じびか', 'じびいんこうか'], aliases: ['耳鼻科', '耳鼻']),
  MedKeyword('小児科', ['しょうにか'], aliases: ['こどもクリニック', 'キッズ']),
  MedKeyword('整形外科', ['せいけいげか', 'せいけい'], aliases: ['整形']),
  MedKeyword('病院', ['びょういん'], category: FacilityCategory.hospital),
  MedKeyword(
    'クリニック',
    ['くりにっく', 'いいん', 'しんりょうじょ'],
    aliases: ['医院', '診療所'],
    category: FacilityCategory.clinic,
  ),
  MedKeyword('産婦人科', ['さんふじんか', 'ふじんか'], aliases: ['婦人科', 'レディース']),
  MedKeyword('精神科', ['せいしんか', 'しんりょうないか', 'めんたる'], aliases: ['心療内科', 'メンタル']),
  MedKeyword('外科', ['げか']),
  MedKeyword('泌尿器科', ['ひにょうきか'], aliases: ['泌尿器']),
  MedKeyword('循環器内科', ['じゅんかんき'], aliases: ['循環器']),
  MedKeyword('消化器内科', ['しょうかき'], aliases: ['消化器', '胃腸']),
  MedKeyword('アレルギー科', ['あれるぎー'], aliases: ['アレルギー']),
];

// OpenStreetMap の診療科タグ → 日本語
const Map<String, String> specialityTagLabels = {
  'internal': '内科',
  'general': '内科',
  'dermatology': '皮膚科',
  'ophthalmology': '眼科',
  'otolaryngology': '耳鼻咽喉科',
  'paediatrics': '小児科',
  'pediatrics': '小児科',
  'orthopaedics': '整形外科',
  'orthopedics': '整形外科',
  'surgery': '外科',
  'general_surgery': '外科',
  'gynaecology': '産婦人科',
  'obstetrics': '産婦人科',
  'psychiatry': '精神科',
  'urology': '泌尿器科',
  'cardiology': '循環器内科',
  'gastroenterology': '消化器内科',
  'allergology': 'アレルギー科',
};

String _addressFromTags(Map<String, dynamic> t) {
  final full = t['addr:full']?.toString();
  if (full != null && full.isNotEmpty) return full;
  String v(String k) => t[k]?.toString() ?? '';
  final area = [
    v('addr:province'),
    v('addr:city'),
    v('addr:suburb'),
    v('addr:quarter'),
    v('addr:neighbourhood'),
  ].join();
  final numbers = [
    v('addr:block_number'),
    v('addr:housenumber'),
  ].where((s) => s.isNotEmpty).join('-');
  return '$area $numbers'.trim();
}

class Facility {
  final String id;
  final String name;
  final double lat;
  final double lon;
  final FacilityCategory category;
  final List<String> specialities;
  final String address;
  final String? phone;
  final String? website;
  final String? openingHours;
  final String reading;

  Facility({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
    required this.category,
    this.specialities = const [],
    this.address = '',
    this.phone,
    this.website,
    this.openingHours,
    this.reading = '',
  });

  late final String searchKey = normalizeJa(
    [name, reading, address, category.label, ...specialities].join('|'),
  );

  LatLng get point => LatLng(lat, lon);

  static Facility? fromOverpass(Map<String, dynamic> e) {
    final tags = Map<String, dynamic>.from(e['tags'] ?? const {});
    final name = (tags['name'] ?? tags['name:ja'] ?? '').toString().trim();
    if (name.isEmpty) return null;
    final center = e['center'];
    final lat = (e['lat'] ?? (center is Map ? center['lat'] : null)) as num?;
    final lon = (e['lon'] ?? (center is Map ? center['lon'] : null)) as num?;
    if (lat == null || lon == null) return null;

    final specs = <String>{};
    final rawSpec = (tags['healthcare:speciality'] ?? '').toString();
    for (final s in rawSpec.split(RegExp(r'[;,]'))) {
      final label = specialityTagLabels[s.trim()];
      if (label != null) specs.add(label);
    }
    // 名前から診療科を推測（例：「山田皮膚科クリニック」→ 皮膚科）
    for (final k in medKeywords) {
      if (k.category != null) continue;
      if (name.contains(k.label) || k.aliases.any((a) => name.contains(a))) {
        specs.add(k.label);
      }
    }

    String? clean(dynamic v) {
      final s = v?.toString().trim();
      return (s == null || s.isEmpty) ? null : s;
    }

    return Facility(
      id: '${e['type']}/${e['id']}',
      name: name,
      lat: lat.toDouble(),
      lon: lon.toDouble(),
      category: FacilityCategory.fromTags(tags),
      specialities: specs.toList(),
      address: _addressFromTags(tags),
      phone: clean(tags['phone'] ?? tags['contact:phone']),
      website: clean(tags['website'] ?? tags['contact:website'] ?? tags['url']),
      openingHours: clean(tags['opening_hours']),
      reading: [
        tags['name:ja-Hira'],
        tags['name:ja_kana'],
        tags['name:ja-Kana'],
        tags['name:ja-Latn'],
        tags['name:ja_rm'],
        tags['name:en'],
      ].where((v) => v != null).join('|'),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'lat': lat,
    'lon': lon,
    'category': category.name,
    'specialities': specialities,
    'address': address,
    'phone': phone,
    'website': website,
    'openingHours': openingHours,
    'reading': reading,
  };

  // 旧バージョンのお気に入り（display_name / osm_id 形式）にも対応
  static Facility? fromJson(Map<String, dynamic> j) {
    final name =
        (j['name'] ?? j['display_name']?.toString().split(',').first ?? '')
            .toString();
    final lat = double.tryParse('${j['lat']}');
    final lon = double.tryParse('${j['lon']}');
    if (name.isEmpty || lat == null || lon == null) return null;
    String? opt(String k) {
      final v = j[k];
      return (v == null || '$v'.isEmpty) ? null : '$v';
    }

    return Facility(
      id: (j['id'] ?? j['osm_id'] ?? '$lat,$lon').toString(),
      name: name,
      lat: lat,
      lon: lon,
      category: FacilityCategory.byName(j['category']?.toString()),
      specialities: List<String>.from(j['specialities'] ?? const []),
      address: (j['address'] ?? '').toString(),
      phone: opt('phone'),
      website: opt('website'),
      openingHours: opt('openingHours'),
      reading: (j['reading'] ?? '').toString(),
    );
  }
}

// OpenStreetMap の施設データ（Overpass API）を取得する
class OverpassApi {
  // 1つ目が混雑・停止していたら次のサーバーを試す
  static const endpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.private.coffee/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
  ];

  static const _amenity =
      '["amenity"~"^(hospital|clinic|doctors|dentist|pharmacy)\$"]';
  static const _healthcare =
      '["healthcare"~"^(hospital|clinic|doctor|dentist|pharmacy)\$"]';

  static String _around(int r, LatLng c) =>
      '(around:$r,${c.latitude},${c.longitude})';

  // 座標を約100m単位に丸めて、同じ場所の再検索はキャッシュを使う
  static LatLng _round(LatLng c) => LatLng(
    double.parse(c.latitude.toStringAsFixed(3)),
    double.parse(c.longitude.toStringAsFixed(3)),
  );

  static Future<List<Facility>> nearby(LatLng c, int radius) {
    final rc = _round(c);
    return _run(
      '[out:json][timeout:25];('
      'nwr$_amenity${_around(radius, rc)};'
      'nwr$_healthcare${_around(radius, rc)};'
      ');out tags center 800;',
    );
  }

  // 名前の一部で広い範囲を検索（words のどれかを名前に含む施設）
  static Future<List<Facility>> searchByName(
    List<String> words,
    LatLng c,
    int radius,
  ) {
    final safe = words
        .map((w) => w.replaceAll(RegExp(r'[\\^$.|?*+()\[\]{}"]'), '').trim())
        .where((w) => w.isNotEmpty)
        .join('|');
    if (safe.isEmpty) return Future.value(const <Facility>[]);
    final name = '["name"~"$safe",i]';
    return _run(
      '[out:json][timeout:25];('
      'nwr$name$_amenity${_around(radius, _round(c))};'
      'nwr$name$_healthcare${_around(radius, _round(c))};'
      ');out tags center 200;',
    );
  }

  // 1件の詳細（電話・サイト・営業時間など）を取得。id は "node/123" 形式
  static Future<Facility?> byId(String id) async {
    final parts = id.split('/');
    if (parts.length != 2 || int.tryParse(parts[1]) == null) return null;
    final list = await _run(
      '[out:json][timeout:15];${parts[0]}(${parts[1]});out tags center;',
    );
    return list.isEmpty ? null : list.first;
  }

  static int _preferred = 0; // 前回うまくいったサーバーから試す
  static final Map<String, List<Facility>> _cache = {};

  static Future<List<Facility>> _run(String ql) async {
    final cached = _cache[ql];
    if (cached != null) return cached;
    Object? lastError;
    for (var i = 0; i < endpoints.length; i++) {
      final idx = (_preferred + i) % endpoints.length;
      final ep = endpoints[idx];
      try {
        final res = await http
            .post(
              Uri.parse(ep),
              headers: kIsWeb
                  ? null
                  : {'User-Agent': 'HealthBuddyApp/1.0 (Flutter)'},
              body: {'data': ql},
            )
            .timeout(const Duration(seconds: 15));
        if (res.statusCode != 200) {
          // 429 = アクセス集中、504 = サーバー混雑 → 次のサーバーへ
          lastError = 'HTTP ${res.statusCode}';
          continue;
        }
        // 日本語が文字化けしないよう UTF-8 で読む
        final data = json.decode(utf8.decode(res.bodyBytes));
        final elements = (data['elements'] as List?) ?? const [];
        final out = <Facility>[];
        final ids = <String>{};
        for (final raw in elements) {
          final f = Facility.fromOverpass(Map<String, dynamic>.from(raw));
          if (f == null || !ids.add(f.id)) continue;
          // 同じ名前で近すぎるもの（建物と入口の重複など）は1つにまとめる
          final dup = out.any(
            (o) =>
                o.name == f.name &&
                Geolocator.distanceBetween(o.lat, o.lon, f.lat, f.lon) < 60,
          );
          if (!dup) out.add(f);
        }
        _preferred = idx;
        if (_cache.length > 40) _cache.clear();
        _cache[ql] = out;
        return out;
      } on TimeoutException {
        lastError = '応答なし';
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception('地図データのサーバーが混雑しています。少し待ってから再試行してください（$lastError）');
  }
}

// 入力途中の文字から施設名を予測する（Photon：検索しながら候補を出すための無料API）
class PhotonApi {
  static const _medical = {
    'hospital',
    'clinic',
    'doctors',
    'dentist',
    'pharmacy',
  };

  static final Map<String, List<Facility>> _cache = {};

  static Future<List<Facility>> suggest(String q, LatLng c) async {
    final key =
        '$q|${c.latitude.toStringAsFixed(2)},${c.longitude.toStringAsFixed(2)}';
    final cached = _cache[key];
    if (cached != null) return cached;
    final out = await _fetch(q, c);
    if (_cache.length > 100) _cache.clear();
    _cache[key] = out;
    return out;
  }

  static Future<List<Facility>> _fetch(String q, LatLng c) async {
    final uri = Uri.https('photon.komoot.io', '/api/', {
      'q': q,
      'lat': '${c.latitude}',
      'lon': '${c.longitude}',
      'limit': '20',
      'osm_tag': 'amenity',
      // 日本全国が対象。近い施設ほど上位に出るよう現在地を優先
      'countrycode': 'JP',
      'zoom': '10',
      'location_bias_scale': '0.3',
    });
    final res = await http
        .get(
          uri,
          headers: kIsWeb
              ? null
              : {'User-Agent': 'HealthBuddyApp/1.0 (Flutter)'},
        )
        .timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final data = json.decode(utf8.decode(res.bodyBytes));
    final out = <Facility>[];
    for (final raw in (data['features'] as List?) ?? const []) {
      final p = Map<String, dynamic>.from(raw['properties'] ?? const {});
      final value = (p['osm_value'] ?? '').toString();
      if (p['osm_key'] != 'amenity' || !_medical.contains(value)) continue;
      final name = (p['name'] ?? '').toString().trim();
      final coords = raw['geometry']?['coordinates'];
      if (name.isEmpty || coords is! List || coords.length < 2) continue;
      final type = switch (p['osm_type']) {
        'N' => 'node',
        'W' => 'way',
        'R' => 'relation',
        _ => 'node',
      };
      final address = [
        p['state'],
        p['city'],
        p['district'],
        p['locality'],
        p['street'],
        p['housenumber'],
      ].where((v) => v != null && '$v'.isNotEmpty).join(' ');
      final specs = <String>[
        for (final k in medKeywords)
          if (k.category == null &&
              (name.contains(k.label) || k.aliases.any(name.contains)))
            k.label,
      ];
      out.add(
        Facility(
          id: '$type/${p['osm_id']}',
          name: name,
          lat: (coords[1] as num).toDouble(),
          lon: (coords[0] as num).toDouble(),
          category: FacilityCategory.fromTags({'amenity': value}),
          specialities: specs,
          address: address,
        ),
      );
    }
    return out;
  }
}

// 確定検索で Photon が使えないときの予備（Nominatim：入力中の連続検索には使わない）
class NominatimApi {
  static const _medical = {
    'hospital',
    'clinic',
    'doctors',
    'dentist',
    'pharmacy',
  };

  static Future<List<Facility>> search(String q, LatLng c) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'format': 'jsonv2',
      'q': q,
      'countrycodes': 'jp',
      'limit': '30',
      'accept-language': 'ja',
      'extratags': '1',
      'viewbox':
          '${c.longitude - 0.5},${c.latitude + 0.5},${c.longitude + 0.5},${c.latitude - 0.5}',
    });
    final res = await http
        .get(
          uri,
          headers: kIsWeb
              ? null
              : {'User-Agent': 'HealthBuddyApp/1.0 (Flutter)'},
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final out = <Facility>[];
    for (final raw in json.decode(utf8.decode(res.bodyBytes)) as List) {
      final m = Map<String, dynamic>.from(raw);
      final type = (m['type'] ?? '').toString();
      if (m['category'] != 'amenity' || !_medical.contains(type)) continue;
      final display = (m['display_name'] ?? '').toString();
      final name =
          ((m['name'] ?? '').toString().isNotEmpty
                  ? m['name']
                  : display.split(',').first)
              .toString()
              .trim();
      final lat = double.tryParse('${m['lat']}');
      final lon = double.tryParse('${m['lon']}');
      if (name.isEmpty || lat == null || lon == null) continue;
      final extra = Map<String, dynamic>.from(m['extratags'] ?? const {});
      // 「名前, 番地, 町, 市, 県, 郵便番号, 日本」→ 日本式の順に並べ替え
      final parts = display
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && e != name && e != '日本')
          .where((e) => !RegExp(r'^\d{3}-?\d{4}$').hasMatch(e))
          .toList();
      String? opt(String k) {
        final v = extra[k] ?? extra['contact:$k'];
        return (v == null || '$v'.isEmpty) ? null : '$v';
      }

      out.add(
        Facility(
          id: '${m['osm_type']}/${m['osm_id']}',
          name: name,
          lat: lat,
          lon: lon,
          category: FacilityCategory.fromTags({'amenity': type}),
          specialities: [
            for (final k in medKeywords)
              if (k.category == null &&
                  (name.contains(k.label) || k.aliases.any(name.contains)))
                k.label,
          ],
          address: parts.reversed.join(' '),
          phone: opt('phone'),
          website: opt('website'),
          openingHours: opt('opening_hours'),
        ),
      );
    }
    return out;
  }
}

String formatDistance(double m) =>
    m < 1000 ? '${m.round()}m' : '${(m / 1000).toStringAsFixed(1)}km';

String walkMinutes(double m) => '徒歩${math.max(1, (m / 80).round())}分';

// OpenStreetMap の営業時間表記を日本語に
String formatOpeningHours(String raw) {
  const days = {
    'Mo': '月',
    'Tu': '火',
    'We': '水',
    'Th': '木',
    'Fr': '金',
    'Sa': '土',
    'Su': '日',
    'PH': '祝',
  };
  var s = raw;
  days.forEach((k, v) => s = s.replaceAll(k, v));
  return s
      .replaceAll('off', '休み')
      .replaceAll('closed', '休み')
      .replaceAll(RegExp(r';\s*'), '\n')
      .replaceAll(',', '、');
}

class MapPage extends StatefulWidget {
  const MapPage({super.key});
  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  static const LatLng _fallback = LatLng(35.6812, 139.7671); // 東京駅
  static const int _nearbyRadius = 3000; // 周辺の読み込み範囲（m）
  static const int _wideRadius = 15000; // 名前検索の範囲（m）

  final MapController _map = MapController();
  final TextEditingController _search = TextEditingController();
  final FocusNode _focus = FocusNode();

  LatLng _myLoc = _fallback;
  bool _hasMyLoc = false;
  LatLng? _loadedCenter;
  LatLng? _cameraCenter;
  bool _showReload = false;
  bool _started = false;
  bool _loading = false;
  String? _error;

  List<Facility> _all = [];
  List<Facility> _favorites = [];
  List<String> _recent = [];

  FacilityCategory? _category;
  MedKeyword? _keyword;
  String? _text;
  bool _favOnly = false;
  Facility? _selected;

  // 入力途中の予測候補（ネット検索）
  Timer? _debounce;
  String _remoteQuery = '';
  List<Facility> _remote = [];
  bool _remoteLoading = false;
  bool _remoteError = false;
  int _nearbyGen = 0; // 古い読み込み結果で上書きしないための番号

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _focus.addListener(_refresh);
    _search.addListener(_onQueryChanged);
  }

  // 文字を入力するたびに、少し待ってから候補をネットで検索
  void _onQueryChanged() {
    _refresh();
    final value = _search.value;
    // 日本語の変換中（下線が付いている間）はネット検索しない
    if (value.composing.isValid && !value.composing.isCollapsed) {
      _debounce?.cancel();
      if (_remoteLoading) setState(() => _remoteLoading = false);
      return;
    }
    final q = value.text.trim();
    if (q == _remoteQuery && !_remoteError) return;
    _debounce?.cancel();
    if (q.isEmpty || !_focus.hasFocus) {
      setState(() {
        _remoteQuery = q;
        _remote = [];
        _remoteLoading = false;
      });
      return;
    }
    setState(() => _remoteLoading = true);
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      try {
        final list = await PhotonApi.suggest(q, _cameraCenter ?? _myLoc);
        if (!mounted || _search.text.trim() != q) return;
        setState(() {
          _remoteQuery = q;
          _remote = list;
          _remoteError = false;
        });
      } catch (e) {
        debugPrint('候補の取得に失敗: $e');
        if (mounted && _search.text.trim() == q) {
          setState(() {
            _remoteQuery = q;
            _remote = [];
            _remoteError = true;
          });
        }
      } finally {
        if (mounted && _search.text.trim() == q) {
          setState(() => _remoteLoading = false);
        }
      }
    });
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  // 地図タブを初めて開いたときに呼ばれる
  void onShown() {
    if (_started) return;
    _started = true;
    _start();
  }

  Future<void> _start() async {
    final ok = await _locate(request: true, silent: true);
    if (!ok) _snack('現在地を取得できないため、東京駅周辺を表示しています');
    await _loadNearby(_myLoc);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------- 保存データ ----------

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final favs = <Facility>[];
    final raw =
        prefs.getString('fav_facilities_v4') ??
        prefs.getString('fav_clinics_v3');
    if (raw != null) {
      try {
        for (final e in json.decode(raw) as List) {
          final f = Facility.fromJson(Map<String, dynamic>.from(e));
          if (f != null) favs.add(f);
        }
      } catch (e) {
        debugPrint('お気に入りの読み込みに失敗: $e');
      }
    }
    if (!mounted) return;
    setState(() {
      _favorites = favs;
      _recent = prefs.getStringList('recent_searches_v1') ?? [];
    });
  }

  Future<void> _saveFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'fav_facilities_v4',
      json.encode(_favorites.map((f) => f.toJson()).toList()),
    );
  }

  Future<void> _addRecent(String q) async {
    _recent.remove(q);
    _recent.insert(0, q);
    if (_recent.length > 8) _recent = _recent.sublist(0, 8);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('recent_searches_v1', _recent);
  }

  bool _isFav(Facility f) => _favorites.any((x) => x.id == f.id);

  void _toggleFavorite(Facility f) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_isFav(f)) {
        _favorites.removeWhere((x) => x.id == f.id);
      } else {
        _favorites.add(f);
      }
    });
    _saveFavorites();
  }

  // ---------- 位置・データ取得 ----------

  double _dist(Facility f) => Geolocator.distanceBetween(
    _myLoc.latitude,
    _myLoc.longitude,
    f.lat,
    f.lon,
  );

  void _safeMove(LatLng p, double zoom) {
    try {
      _map.move(p, zoom);
    } catch (_) {}
  }

  Future<bool> _locate({bool request = false, bool silent = false}) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (!silent) _snack('位置情報サービスがオフになっています');
        return false;
      }
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied && request) {
        p = await Geolocator.requestPermission();
      }
      if (p == LocationPermission.denied ||
          p == LocationPermission.deniedForever) {
        if (!silent) _snack('位置情報の利用が許可されていません');
        return false;
      }
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 15));
      if (!mounted) return false;
      setState(() {
        _myLoc = LatLng(pos.latitude, pos.longitude);
        _hasMyLoc = true;
      });
      _safeMove(_myLoc, 15);
      return true;
    } catch (e) {
      debugPrint('位置情報エラー: $e');
      if (!silent) _snack('現在地を取得できませんでした');
      return false;
    }
  }

  Future<void> _loadNearby(LatLng center) async {
    final gen = ++_nearbyGen;
    setState(() {
      _loading = true;
      _error = null;
      _showReload = false;
    });
    try {
      final list = await OverpassApi.nearby(center, _nearbyRadius);
      if (!mounted || gen != _nearbyGen) return;
      // 検索で追加した遠くの施設は残す
      final ids = list.map((f) => f.id).toSet();
      final keep = _all.where(
        (f) =>
            !ids.contains(f.id) &&
            Geolocator.distanceBetween(
                  center.latitude,
                  center.longitude,
                  f.lat,
                  f.lon,
                ) >
                _nearbyRadius,
      );
      setState(() {
        _all = [...list, ...keep];
        _loadedCenter = center;
      });
      if (list.isEmpty) _snack('この周辺では医療機関が見つかりませんでした');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e'.replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // keyword を渡すと、その診療科名を名前に含む施設を広い範囲で探す
  Future<void> _searchWide(String q, {MedKeyword? keyword}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      List<Facility> list = [];
      Object? overpassError;
      try {
        list = await OverpassApi.searchByName(
          keyword == null ? [q] : [keyword.label, ...keyword.aliases],
          _cameraCenter ?? _myLoc,
          _wideRadius,
        );
      } catch (e) {
        overpassError = e; // 混雑していても下の全国検索は試す
      }
      if (!mounted) return;
      if (overpassError != null && keyword != null) throw overpassError;
      final ids = _all.map((f) => f.id).toSet();
      setState(() {
        _all = [..._all, ...list.where((f) => !ids.contains(f.id))];
        _text = keyword == null ? q : null;
        _keyword = keyword;
        _category = null;
        _favOnly = false;
      });
      var hits = _visible;
      // 15km以内に無ければ、日本全国から施設名で探す
      if (hits.isEmpty && keyword == null) {
        try {
          List<Facility> far;
          try {
            far = await PhotonApi.suggest(q, _myLoc);
            if (far.isEmpty) far = await NominatimApi.search(q, _myLoc);
          } catch (_) {
            far = await NominatimApi.search(q, _myLoc);
          }
          if (!mounted) return;
          final known = _all.map((f) => f.id).toSet();
          setState(
            () => _all = [..._all, ...far.where((f) => !known.contains(f.id))],
          );
          hits = _visible;
          if (hits.isEmpty && far.isNotEmpty) {
            _fitTo(far.take(30).toList());
            _openList(far);
            return;
          }
        } catch (e) {
          debugPrint('全国検索に失敗: $e');
        }
      }
      if (hits.isEmpty) {
        _snack('「$q」に一致する医療機関は見つかりませんでした');
      } else {
        _snack('${hits.length}件見つかりました');
        _fitTo(hits.take(30).toList());
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e'.replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onMapMoved(MapCamera camera, bool hasGesture) {
    _cameraCenter = camera.center;
    if (!hasGesture || _loadedCenter == null || _loading) return;
    final far =
        Geolocator.distanceBetween(
          camera.center.latitude,
          camera.center.longitude,
          _loadedCenter!.latitude,
          _loadedCenter!.longitude,
        ) >
        _nearbyRadius * 0.6;
    if (far != _showReload) setState(() => _showReload = far);
  }

  // ---------- 絞り込み ----------

  List<Facility> get _visible {
    Iterable<Facility> list = _favOnly ? _favorites : _all;
    if (_category != null) list = list.where((f) => f.category == _category);
    final k = _keyword;
    if (k != null) list = list.where(k.matches);
    final t = _text;
    if (t != null && t.isNotEmpty) {
      final q = normalizeJa(t);
      list = list.where((f) => f.searchKey.contains(q));
    }
    final out = list.toList()..sort((a, b) => _dist(a).compareTo(_dist(b)));
    return out.length > 400 ? out.sublist(0, 400) : out;
  }

  String get _filterLabel {
    if (_favOnly) return 'お気に入り';
    if (_keyword != null) return _keyword!.label;
    if (_category != null) return _category!.label;
    if (_text != null) return '「$_text」';
    return '周辺の医療機関';
  }

  void _resetFilters() {
    _search.clear();
    setState(() {
      _category = null;
      _keyword = null;
      _text = null;
      _favOnly = false;
    });
  }

  void _setCategory(FacilityCategory c) {
    setState(() {
      _category = _category == c ? null : c;
      _keyword = null;
      _text = null;
      _favOnly = false;
    });
    _search.clear();
    if (_category != null) _afterFilter();
  }

  void _toggleFavOnly() {
    setState(() => _favOnly = !_favOnly);
    if (_favOnly && _favorites.isEmpty) {
      _snack('お気に入りはまだありません。施設の詳細画面の ♡ から登録できます');
    } else if (_favOnly) {
      _afterFilter();
    }
  }

  void _applyKeyword(MedKeyword k) {
    _focus.unfocus();
    _search.text = k.label;
    setState(() {
      _text = null;
      _favOnly = false;
      if (k.category != null) {
        _category = k.category;
        _keyword = null;
      } else {
        _keyword = k;
        _category = null;
      }
    });
    _addRecent(k.label);
    // 近くのデータに無ければ、診療科名を含む施設を広い範囲で探す
    if (_visible.isEmpty && k.category == null) {
      _searchWide(k.label, keyword: k);
    } else {
      _afterFilter();
    }
  }

  void _applyText(String raw) {
    final q = raw.trim();
    if (q.isEmpty) return;
    // 「ひふか」「皮膚科」など診療科そのものなら診療科で絞り込む
    final n = normalizeJa(q);
    for (final k in medKeywords) {
      if (k.exactly(n)) {
        _applyKeyword(k);
        return;
      }
    }
    _focus.unfocus();
    setState(() {
      _text = q;
      _keyword = null;
      _category = null;
      _favOnly = false;
    });
    _addRecent(q);
    if (_visible.isEmpty) {
      _searchWide(q); // 近くになければ広い範囲を名前で検索
    } else {
      _afterFilter();
    }
  }

  void _afterFilter() {
    final v = _visible;
    if (v.isEmpty) {
      _snack('条件に合う医療機関がこの周辺にありません');
      return;
    }
    _fitTo(v.take(30).toList());
  }

  void _fitTo(List<Facility> list) {
    if (list.isEmpty) return;
    try {
      if (list.length == 1) {
        _map.move(list.first.point, 16.5);
        return;
      }
      _map.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints([for (final f in list) f.point]),
          padding: const EdgeInsets.fromLTRB(48, 190, 48, 120),
          maxZoom: 17,
        ),
      );
    } catch (_) {}
  }

  // ---------- 予測サジェスト ----------

  List<MedKeyword> _keywordSuggestions(String q) {
    final n = normalizeJa(q);
    return medKeywords.where((k) => k.matchesQuery(n)).take(4).toList();
  }

  List<Facility> _facilitySuggestions(String q) {
    final n = normalizeJa(q);
    if (n.isEmpty) return [];
    final pool = <String, Facility>{
      for (final f in [..._all, ..._favorites]) f.id: f,
    }.values;
    int rank(Facility f) {
      final name = normalizeJa(f.name);
      if (name.startsWith(n)) return 0;
      if (name.contains(n)) return 1;
      return 2;
    }

    final hits = pool.where((f) => f.searchKey.contains(n)).toList()
      ..sort((a, b) {
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : _dist(a).compareTo(_dist(b));
      });
    return hits.take(8).toList();
  }

  // ---------- 詳細・一覧 ----------

  void _open(String url) async {
    try {
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) _snack('開けませんでした');
    } catch (e) {
      _snack('開けませんでした: $e');
    }
  }

  // 詳細シートに隠れないよう、ピンが画面の上寄りに来るように移動
  void _focusOn(Facility f, double zoom) {
    try {
      final h = MediaQuery.of(context).size.height;
      final mpp =
          156543.03392 * math.cos(f.lat * math.pi / 180) / math.pow(2, zoom);
      final dLat = (h * 0.2 * mpp) / 111320;
      _map.move(LatLng(f.lat - dLat, f.lon), zoom);
    } catch (_) {}
  }

  void _openDetail(Facility f) {
    _focus.unfocus();
    setState(() => _selected = f);
    double zoom = 16.5;
    try {
      zoom = math.max(_map.camera.zoom, 16.0);
    } catch (_) {}
    _focusOn(f, zoom);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => _detailSheet(ctx, f, () {
          _toggleFavorite(f);
          setSheet(() {});
        }),
      ),
    ).whenComplete(() {
      if (mounted) setState(() => _selected = null);
    });
  }

  Widget _detailSheet(BuildContext ctx, Facility f, VoidCallback onFav) {
    final fav = _isFav(f);
    final c = f.category;
    final d = _dist(f);
    final website = f.website;
    final websiteUrl = website == null
        ? null
        : (website.startsWith('http') ? website : 'https://$website');
    final phoneDisplay = f.phone?.split(';').first.trim();
    final phone = phoneDisplay?.replaceAll(RegExp(r'[^0-9+]'), '');
    final hasPhone = phone != null && phone.isNotEmpty;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        20 + MediaQuery.of(ctx).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: c.color.withAlpha(30),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(c.icon, color: c.color, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      f.name,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppColors.ink,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _hasMyLoc
                          ? '${c.label}・${formatDistance(d)}（${walkMinutes(d)}）'
                          : c.label,
                      style: const TextStyle(
                        color: AppColors.sub,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: fav ? 'お気に入りを解除' : 'お気に入りに追加',
                onPressed: onFav,
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (child, anim) =>
                      ScaleTransition(scale: anim, child: child),
                  child: Icon(
                    fav
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    key: ValueKey(fav),
                    color: fav ? AppColors.danger : AppColors.sub,
                    size: 30,
                  ),
                ),
              ),
            ],
          ),
          if (f.specialities.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: f.specialities
                  .map(
                    (s) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: c.color.withAlpha(24),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        s,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: c.color,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _ActionTile(
                  icon: Icons.directions_rounded,
                  label: 'ルート',
                  color: AppColors.primary,
                  onTap: () => _open(
                    'https://www.google.com/maps/dir/?api=1&destination=${f.lat},${f.lon}&travelmode=walking',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ActionTile(
                  icon: Icons.call_rounded,
                  label: '電話',
                  color: const Color(0xFF2E7DD7),
                  onTap: hasPhone ? () => _open('tel:$phone') : null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ActionTile(
                  icon: websiteUrl != null
                      ? Icons.public_rounded
                      : Icons.search_rounded,
                  label: websiteUrl != null ? '公式サイト' : 'Webで調べる',
                  color: const Color(0xFF8E4EC6),
                  onTap: () => _open(
                    websiteUrl ??
                        'https://www.google.com/search?q=${Uri.encodeComponent('${f.name} ${f.address}')}',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _InfoRow(
            Icons.place_rounded,
            f.address.isEmpty ? '住所情報なし' : f.address,
          ),
          if (f.openingHours != null)
            _InfoRow(
              Icons.schedule_rounded,
              formatOpeningHours(f.openingHours!),
            ),
          if (hasPhone) _InfoRow(Icons.call_outlined, phoneDisplay!),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _open(
                'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent('${f.name} ${f.address}')}',
              ),
              icon: const Icon(Icons.map_rounded),
              label: const Text('Googleマップで口コミ・営業時間を見る'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '施設情報は OpenStreetMap のデータです。最新でない場合があるため、受診前に公式情報をご確認ください。',
            style: TextStyle(fontSize: 11, color: AppColors.sub),
          ),
        ],
      ),
    );
  }

  void _openList(List<Facility> list) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.35,
        maxChildSize: 0.95,
        builder: (ctx, sc) => Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _filterLabel,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    '${list.length}件・近い順',
                    style: const TextStyle(color: AppColors.sub),
                  ),
                ],
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? const Center(
                      child: Text(
                        '該当する医療機関はありません',
                        style: TextStyle(color: AppColors.sub),
                      ),
                    )
                  : ListView.separated(
                      controller: sc,
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const Divider(
                        height: 1,
                        indent: 76,
                        color: AppColors.line,
                      ),
                      itemBuilder: (ctx, i) {
                        final f = list[i];
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 4,
                          ),
                          leading: IconBubble(
                            f.category.icon,
                            f.category.color,
                          ),
                          title: Text(
                            f.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Text(
                            [
                              f.category.label,
                              ...f.specialities.take(3),
                            ].join('・'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: _hasMyLoc
                              ? Text(
                                  formatDistance(_dist(f)),
                                  style: const TextStyle(
                                    color: AppColors.sub,
                                    fontWeight: FontWeight.w600,
                                  ),
                                )
                              : null,
                          onTap: () {
                            Navigator.pop(ctx);
                            _openDetail(f);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 画面 ----------

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final selected = _selected;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: LayoutBuilder(
        builder: (context, cons) => Stack(
          children: [
            FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: _fallback,
                initialZoom: 14,
                onPositionChanged: _onMapMoved,
                onTap: (_, __) {
                  if (_focus.hasFocus) _focus.unfocus();
                },
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                ),
              ),
              children: [
                // OpenStreetMap 公式タイル（APIキー不要）
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.flutter_application_1',
                  maxZoom: 19,
                ),
                MarkerLayer(
                  markers: [
                    for (final f in visible)
                      if (f.id != selected?.id)
                        Marker(
                          point: f.point,
                          width: 52,
                          height: 52,
                          child: FacilityPin(
                            facility: f,
                            selected: false,
                            favorite: _isFav(f),
                            onTap: () => _openDetail(f),
                          ),
                        ),
                    if (_hasMyLoc)
                      Marker(
                        point: _myLoc,
                        width: 32,
                        height: 32,
                        child: const MyLocationDot(),
                      ),
                    // 選択中のピンは一番手前に大きく表示
                    if (selected != null)
                      Marker(
                        point: selected.point,
                        width: 56,
                        height: 56,
                        child: FacilityPin(
                          facility: selected,
                          selected: true,
                          favorite: _isFav(selected),
                          onTap: () => _openDetail(selected),
                        ),
                      ),
                  ],
                ),
              ],
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _searchBar(),
                      if (_focus.hasFocus)
                        _suggestionPanel(
                          _search.text,
                          (cons.maxHeight -
                                  150 -
                                  MediaQuery.of(context).viewInsets.bottom)
                              .clamp(160.0, 520.0),
                        )
                      else ...[
                        const SizedBox(height: 10),
                        _filterChips(),
                        if (_showReload && !_loading)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Center(
                              child: _Pill(
                                color: AppColors.ink,
                                onTap: () =>
                                    _loadNearby(_cameraCenter ?? _myLoc),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.refresh_rounded,
                                      size: 18,
                                      color: Colors.white,
                                    ),
                                    SizedBox(width: 6),
                                    Text(
                                      'このエリアで探す',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            Positioned(left: 16, bottom: 22, child: _statusPill(visible)),
            Positioned(
              right: 16,
              bottom: 22,
              child: Material(
                color: Colors.white,
                shape: const CircleBorder(),
                elevation: 4,
                shadowColor: const Color(0x55000000),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () async {
                    final ok = await _locate(request: true);
                    if (!ok) return;
                    final lc = _loadedCenter;
                    if (lc == null ||
                        Geolocator.distanceBetween(
                              lc.latitude,
                              lc.longitude,
                              _myLoc.latitude,
                              _myLoc.longitude,
                            ) >
                            1500) {
                      _loadNearby(_myLoc);
                    }
                  },
                  child: const Padding(
                    padding: EdgeInsets.all(14),
                    child: Icon(
                      Icons.my_location_rounded,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ),
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 3,
              child: IgnorePointer(
                child: Center(
                  child: Text(
                    '© OpenStreetMap contributors',
                    style: TextStyle(fontSize: 9, color: AppColors.sub),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchBar() {
    final hasText = _search.text.isNotEmpty;
    return Container(
      height: 54,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(27),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          const SizedBox(width: 4),
          IconButton(
            icon: Icon(
              _focus.hasFocus ? Icons.arrow_back_rounded : Icons.search_rounded,
              color: AppColors.ink,
            ),
            onPressed: () {
              if (_focus.hasFocus) {
                _focus.unfocus();
              } else {
                _focus.requestFocus();
              }
            },
          ),
          Expanded(
            child: TextField(
              controller: _search,
              focusNode: _focus,
              textInputAction: TextInputAction.search,
              onSubmitted: _applyText,
              style: const TextStyle(fontSize: 16, color: AppColors.ink),
              decoration: const InputDecoration(
                hintText: '病院・薬局・診療科を検索',
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
          if (hasText)
            IconButton(
              icon: const Icon(Icons.close_rounded, color: AppColors.sub),
              onPressed: _resetFilters,
            )
          else if (_loading)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _filterChips() {
    Widget chip({
      required String label,
      IconData? icon,
      Color color = AppColors.ink,
      required bool selected,
      required VoidCallback onTap,
    }) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: selected ? color : Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x1F000000),
                  blurRadius: 10,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: selected ? Colors.white : color),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : AppColors.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final noFilter =
        _category == null && _keyword == null && !_favOnly && _text == null;
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        children: [
          chip(label: 'すべて', selected: noFilter, onTap: _resetFilters),
          for (final c in const [
            FacilityCategory.hospital,
            FacilityCategory.clinic,
            FacilityCategory.dentist,
            FacilityCategory.pharmacy,
          ])
            chip(
              label: c.label,
              icon: c.icon,
              color: c.color,
              selected: _category == c,
              onTap: () => _setCategory(c),
            ),
          chip(
            label: 'お気に入り',
            icon: Icons.favorite_rounded,
            color: AppColors.danger,
            selected: _favOnly,
            onTap: _toggleFavOnly,
          ),
          if (_keyword != null)
            chip(
              label: '${_keyword!.label}  ✕',
              icon: Icons.medical_information_rounded,
              color: AppColors.primaryDark,
              selected: true,
              onTap: _resetFilters,
            ),
        ],
      ),
    );
  }

  Widget _suggestionPanel(String raw, double maxHeight) {
    final q = raw.trim();
    final children = <Widget>[];

    Widget header(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Text(
        t,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: AppColors.sub,
        ),
      ),
    );

    if (q.isEmpty) {
      if (_recent.isNotEmpty) {
        children.add(header('最近の検索'));
        for (final r in _recent) {
          children.add(
            ListTile(
              dense: true,
              leading: const Icon(Icons.history_rounded, color: AppColors.sub),
              title: Text(r, style: const TextStyle(fontSize: 15)),
              onTap: () {
                _search.text = r;
                _applyText(r);
              },
            ),
          );
        }
      }
      children.add(header('診療科・種類から探す'));
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: medKeywords
                .take(10)
                .map(
                  (k) => ActionChip(
                    avatar: Icon(k.icon, size: 16, color: k.color),
                    label: Text(k.label),
                    backgroundColor: Colors.white,
                    side: const BorderSide(color: AppColors.line),
                    shape: const StadiumBorder(),
                    onPressed: () => _applyKeyword(k),
                  ),
                )
                .toList(),
          ),
        ),
      );
      if (_favorites.isNotEmpty) {
        children.add(header('お気に入り'));
        children.addAll(_favorites.take(5).map((f) => _facilityTile(f, '')));
      }
    } else {
      // 入力した言葉そのままで検索（いちばん上に置いてキーボードで隠れないように）
      children.add(
        ListTile(
          leading: const IconBubble(
            Icons.search_rounded,
            AppColors.ink,
            size: 38,
          ),
          title: Text('「$q」で検索', style: const TextStyle(fontSize: 15)),
          subtitle: const Text(
            '近くになければ広い範囲を探します',
            style: TextStyle(fontSize: 12, color: AppColors.sub),
          ),
          onTap: () => _applyText(q),
        ),
      );
      final keywords = _keywordSuggestions(q);
      if (keywords.isNotEmpty) children.add(header('診療科・種類'));
      for (final k in keywords) {
        children.add(
          ListTile(
            leading: IconBubble(k.icon, k.color, size: 38),
            title: _highlight(k.label, q),
            subtitle: Text(
              k.category != null
                  ? '近くの${k.label}をすべて表示'
                  : '${k.label}のある医療機関を表示',
              style: const TextStyle(fontSize: 12, color: AppColors.sub),
            ),
            onTap: () => _applyKeyword(k),
          ),
        );
      }
      final local = _facilitySuggestions(q);
      final shown = local.map((f) => f.id).toSet();
      final remote = _remoteQuery == q
          ? _remote.where((f) => shown.add(f.id)).toList()
          : <Facility>[];
      remote.sort((a, b) => _dist(a).compareTo(_dist(b)));
      if (local.isNotEmpty || remote.isNotEmpty) children.add(header('施設'));
      for (final f in local) {
        children.add(_facilityTile(f, q));
      }
      for (final f in remote.take(10)) {
        children.add(_facilityTile(f, q));
      }
      if (_remoteLoading) {
        children.add(
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 12),
                Text('候補を探しています…', style: TextStyle(color: AppColors.sub)),
              ],
            ),
          ),
        );
      } else if (local.isEmpty && remote.isEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(
              _search.value.composing.isValid &&
                      !_search.value.composing.isCollapsed
                  ? '変換を確定すると施設名の候補を探します'
                  : _remoteError
                  ? '候補を取得できませんでした（通信が混雑しています）。上の「で検索」を押すと別の方法で探します'
                  : '施設名の候補はありません。漢字で入力するか、上の「で検索」を押してください',
              style: TextStyle(fontSize: 12, color: AppColors.sub),
            ),
          ),
        );
      }
    }

    return Container(
      margin: const EdgeInsets.only(top: 8),
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Material(
          color: Colors.white,
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 6),
            shrinkWrap: true,
            children: children,
          ),
        ),
      ),
    );
  }

  Widget _facilityTile(Facility f, String q) => ListTile(
    leading: IconBubble(f.category.icon, f.category.color, size: 38),
    title: _highlight(f.name, q),
    subtitle: Text(
      [
        f.category.label,
        ...f.specialities.take(2),
        if (_hasMyLoc) formatDistance(_dist(f)),
      ].join('・'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12, color: AppColors.sub),
    ),
    trailing: _isFav(f)
        ? const Icon(Icons.favorite_rounded, color: AppColors.danger, size: 18)
        : null,
    onTap: () {
      _addRecent(f.name);
      _openFacility(f);
    },
  );

  // 予測候補から選んだ施設は、電話番号などの詳細を取得してから開く
  Future<void> _openFacility(Facility f) async {
    _focus.unfocus();
    final known = _all.where((x) => x.id == f.id);
    if (known.isNotEmpty) {
      _openDetail(known.first);
      return;
    }
    var target = f;
    setState(() => _loading = true);
    try {
      final detail = await OverpassApi.byId(f.id);
      if (detail != null) target = detail;
    } catch (e) {
      debugPrint('詳細の取得に失敗: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (!mounted) return;
    setState(() => _all = [..._all, target]);
    _openDetail(target);
  }

  // 入力した文字を色付きで表示
  Widget _highlight(String text, String q) {
    const base = TextStyle(
      fontSize: 15,
      color: AppColors.ink,
      fontWeight: FontWeight.w600,
    );
    final i = q.isEmpty ? -1 : text.indexOf(q);
    if (i < 0) {
      return Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: base,
      );
    }
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(text: text.substring(0, i)),
          TextSpan(
            text: text.substring(i, i + q.length),
            style: const TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.w800,
            ),
          ),
          TextSpan(text: text.substring(i + q.length)),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _statusPill(List<Facility> visible) {
    if (_error != null) {
      return _Pill(
        color: const Color(0xFFFFEEEE),
        onTap: () => _loadNearby(_cameraCenter ?? _myLoc),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off_rounded, size: 18, color: AppColors.danger),
            SizedBox(width: 8),
            Text(
              '読み込みに失敗・タップで再試行',
              style: TextStyle(
                color: AppColors.danger,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }
    if (_loading) {
      return const _Pill(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Text('医療機関を読み込み中…', style: TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      );
    }
    if (!_started) return const SizedBox.shrink();
    return _Pill(
      onTap: () => _openList(visible),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.format_list_bulleted_rounded,
            size: 18,
            color: AppColors.primary,
          ),
          const SizedBox(width: 8),
          Text(
            '$_filterLabel ${visible.length}件',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.sub),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final Color color;
  const _Pill({required this.child, this.onTap, this.color = Colors.white});

  @override
  Widget build(BuildContext context) => Material(
    color: color,
    shape: const StadiumBorder(),
    elevation: 4,
    shadowColor: const Color(0x55000000),
    child: InkWell(
      customBorder: const StadiumBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: child,
      ),
    ),
  );
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = onTap == null ? const Color(0xFFB8C2BF) : color;
    return Material(
      color: c.withAlpha(24),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: [
              Icon(icon, color: c, size: 26),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  color: c,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoRow(this.icon, this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: AppColors.sub),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.ink,
              height: 1.5,
            ),
          ),
        ),
      ],
    ),
  );
}

class FacilityPin extends StatelessWidget {
  final Facility facility;
  final bool selected;
  final bool favorite;
  final VoidCallback onTap;
  const FacilityPin({
    super.key,
    required this.facility,
    required this.selected,
    required this.favorite,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = facility.category;
    final size = selected ? 48.0 : 34.0;
    return Center(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutBack,
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: c.color,
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white,
                width: selected ? 3.5 : 2.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: c.color.withAlpha(110),
                  blurRadius: selected ? 16 : 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Icon(c.icon, color: Colors.white, size: selected ? 24 : 18),
                if (favorite)
                  Positioned(
                    right: -5,
                    top: -5,
                    child: Container(
                      width: 17,
                      height: 17,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.favorite_rounded,
                        size: 11,
                        color: AppColors.danger,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MyLocationDot extends StatelessWidget {
  const MyLocationDot({super.key});
  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      color: Color(0x332E7DD7),
      shape: BoxShape.circle,
    ),
    alignment: Alignment.center,
    child: Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: const Color(0xFF2E7DD7),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 6)],
      ),
    ),
  );
}

// =====================================================================
//  4. 設定（変更は自動保存）
// =====================================================================

class SettingsPage extends StatefulWidget {
  final List<String> initialTimes;
  final bool initialNotif;
  final Future<String> Function(List<String>, bool) onSave;
  const SettingsPage({
    required this.initialTimes,
    required this.initialNotif,
    required this.onSave,
    super.key,
  });
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late List<String> _times;
  late bool _notif;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _times = List.from(widget.initialTimes);
    _notif = widget.initialNotif;
  }

  // 親の設定が変わったら（読み込み・保存後）画面側にも反映する
  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTimes != widget.initialTimes ||
        oldWidget.initialNotif != widget.initialNotif) {
      _times = List.from(widget.initialTimes);
      _notif = widget.initialNotif;
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final msg = await widget.onSave(List.from(_times), _notif);
    if (!mounted) return;
    setState(() => _saving = false);
    _snack(msg);
  }

  String _fmt(TimeOfDay p) =>
      "${p.hour.toString().padLeft(2, '0')}:${p.minute.toString().padLeft(2, '0')}";

  Future<void> _addTime() async {
    final p = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (p == null || !mounted) return;
    final s = _fmt(p);
    if (_times.contains(s)) {
      _snack("$s はすでに登録されています");
      return;
    }
    setState(() {
      _times.add(s);
      _times.sort();
    });
    _save();
  }

  Future<void> _editTime(int index) async {
    final parts = _times[index].split(':');
    final p = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: int.parse(parts[0]),
        minute: int.parse(parts[1]),
      ),
    );
    if (p == null || !mounted) return;
    final s = _fmt(p);
    if (s == _times[index]) return;
    if (_times.contains(s)) {
      _snack("$s はすでに登録されています");
      return;
    }
    setState(() {
      _times[index] = s;
      _times.sort();
    });
    _save();
  }

  void _removeTime(String t) {
    setState(() => _times.remove(t));
    _save();
  }

  // 即時テスト通知
  Future<void> _showImmediateNotification() async {
    await flutterLocalNotificationsPlugin.show(
      123,
      'お薬を飲む時間です！',
      'お薬を飲んで、記録をつけましょう。',
      notificationDetails(),
    );
  }

  // 1分後の予約通知テスト（予約通知が届くかの確認用）
  Future<void> _scheduleTestIn1Minute() async {
    try {
      final mode = await resolveScheduleMode();
      await flutterLocalNotificationsPlugin.zonedSchedule(
        124,
        '予約通知のテスト',
        '予約通知は正常に届いています',
        tz.TZDateTime.now(tz.local).add(const Duration(minutes: 1)),
        notificationDetails(),
        androidScheduleMode: mode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
      _snack("1分後に通知を予約しました。アプリを閉じて待ってみてください");
    } catch (e) {
      _snack("予約に失敗しました: $e");
    }
  }

  Future<void> _showPending() async {
    final pending = await flutterLocalNotificationsPlugin
        .pendingNotificationRequests();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("予約中の通知（${pending.length}件）"),
        content: SingleChildScrollView(
          child: Text(
            pending.isEmpty
                ? "予約されている通知はありません"
                : pending
                      .map((p) => "・${p.title}\n  ${p.body ?? ''}")
                      .join("\n"),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("閉じる"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 68,
        titleSpacing: 20,
        title: const Text(
          '設定',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
        ),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.only(right: 20),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          const SectionTitle('通知'),
          const SizedBox(height: 10),
          Panel(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                SwitchListTile(
                  value: _notif,
                  onChanged: _saving
                      ? null
                      : (v) {
                          setState(() => _notif = v);
                          _save();
                        },
                  secondary: const IconBubble(
                    Icons.notifications_active_rounded,
                    AppColors.primary,
                  ),
                  title: const Text(
                    '服薬リマインダー',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: const Text('服薬の5分前と、時間ちょうどにお知らせします'),
                ),
                if (kIsWeb)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: Text(
                      'ブラウザ版では通知は使えません。Android（実機・エミュレータ）で確認してください。',
                      style: TextStyle(color: AppColors.danger, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              const SectionTitle('服薬スケジュール'),
              const Spacer(),
              Text(
                '1日${_times.length}回',
                style: const TextStyle(
                  color: AppColors.sub,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Panel(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                if (_times.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'まだ時間が登録されていません',
                      style: TextStyle(color: AppColors.sub),
                    ),
                  ),
                for (var i = 0; i < _times.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, indent: 72, color: AppColors.line),
                  ListTile(
                    onTap: () => _editTime(i),
                    leading: IconBubble(
                      periodOf(_times[i]).icon,
                      periodOf(_times[i]).color,
                    ),
                    title: Text(
                      _times[i],
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    subtitle: Text('${periodOf(_times[i]).label}・タップで時間を変更'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline_rounded),
                      color: AppColors.sub,
                      onPressed: () => _removeTime(_times[i]),
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _addTime,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('時間を追加'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const SectionTitle('通知のテスト'),
          const SizedBox(height: 10),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '通知が届くか確認できます。「1分後に通知」はアプリを閉じて待ってください。',
                  style: TextStyle(color: AppColors.sub, fontSize: 13),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: kIsWeb ? null : _showImmediateNotification,
                      icon: const Icon(Icons.notifications_rounded),
                      label: const Text('今すぐ通知'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: kIsWeb ? null : _scheduleTestIn1Minute,
                      icon: const Icon(Icons.timer_rounded),
                      label: const Text('1分後に通知'),
                    ),
                    OutlinedButton.icon(
                      onPressed: kIsWeb ? null : _showPending,
                      icon: const Icon(Icons.list_rounded),
                      label: const Text('予約中の通知'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const Center(
            child: Text(
              '変更は自動で保存されます',
              style: TextStyle(fontSize: 12, color: AppColors.sub),
            ),
          ),
        ],
      ),
    );
  }
}
