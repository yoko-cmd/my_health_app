import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:intl/intl.dart';
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
import 'dart:convert';
import 'firebase_options.dart';
import 'secrets.dart';

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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  tz.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation('Asia/Tokyo'));

  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
  );
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  final flutterLocal = flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  await flutterLocal?.createNotificationChannel(channel);

  runApp(const HealthBuddyApp());
}

class HealthBuddyApp extends StatelessWidget {
  const HealthBuddyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'my_health_app',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: const MainNavigationScreen(),
    );
  }
}

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});
  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  final String myId = "user_001";
  List<String> _medicationTimes = [];
  bool _isNotificationOn = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    final android = flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.requestNotificationsPermission();
    await android?.requestExactAlarmsPermission();

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      await Geolocator.requestPermission();
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _medicationTimes = prefs.getStringList('med_times') ?? ["08:00", "19:00"];
      _isNotificationOn = prefs.getBool('notif_on') ?? true;
    });
    if (_isNotificationOn) _scheduleAllNotifications();
  }

  Future<void> _saveSettings(List<String> times, bool notif) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('med_times', times);
    await prefs.setBool('notif_on', notif);
    setState(() {
      _medicationTimes = times;
      _isNotificationOn = notif;
    });
    if (notif)
      _scheduleAllNotifications();
    else
      flutterLocalNotificationsPlugin.cancelAll();
  }

  Future<void> _scheduleAllNotifications() async {
    await flutterLocalNotificationsPlugin.cancelAll();
    for (int i = 0; i < _medicationTimes.length; i++) {
      final parts = _medicationTimes[i].split(':');
      final h = int.parse(parts[0]);
      final m = int.parse(parts[1]);
      await _sendScheduled(i * 2, "💊 服薬5分前です", "準備をしましょう", h, m - 5);
      await _sendScheduled(i * 2 + 1, "⏰ お薬の時間です", "記録をつけましょう", h, m);
    }
  }

  Future<void> _sendScheduled(
    int id,
    String title,
    String body,
    int h,
    int m,
  ) async {
    int finalM = m;
    int finalH = h;
    if (finalM < 0) {
      finalM += 60;
      finalH = (finalH - 1) % 24;
    }
    await flutterLocalNotificationsPlugin.zonedSchedule(
      id,
      title,
      body,
      _nextInstance(finalH, finalM),
      NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          importance: Importance.max,
          priority: Priority.high,
          fullScreenIntent: true,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  tz.TZDateTime _nextInstance(int h, int m) {
    final now = tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime(tz.local, now.year, now.month, now.day, h, m);
    if (scheduled.isBefore(now))
      scheduled = scheduled.add(const Duration(days: 1));
    return scheduled;
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = [
      MedicationCalendarPage(userId: myId, activeTimings: _medicationTimes),
      AIChatPage(userId: myId),
      const MapPage(),
      SettingsPage(
        initialTimes: _medicationTimes,
        initialNotif: _isNotificationOn,
        onSave: _saveSettings,
      ),
    ];
    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.calendar_month), label: "服薬"),
          NavigationDestination(icon: Icon(Icons.auto_awesome), label: "AI栄養"),
          NavigationDestination(icon: Icon(Icons.map), label: "地図"),
          NavigationDestination(icon: Icon(Icons.settings), label: "設定"),
        ],
      ),
    );
  }
}

// --- 1. 服薬管理 (はなまる復活版) ---
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
  DateTime _selectedDay = DateTime.now();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("服薬管理")),
      body: Column(
        children: [
          TableCalendar(
            focusedDay: _selectedDay,
            firstDay: DateTime.utc(2024, 1, 1),
            lastDay: DateTime.utc(2030, 12, 31),
            selectedDayPredicate: (d) => isSameDay(_selectedDay, d),
            onDaySelected: (s, f) => setState(() => _selectedDay = s),
            headerStyle: const HeaderStyle(formatButtonVisible: false),
            // ★はなまるを表示するビルダー
            calendarBuilders: CalendarBuilders(
              markerBuilder: (context, date, events) {
                return StreamBuilder<DocumentSnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('users')
                      .doc(widget.userId)
                      .collection('med_logs')
                      .doc(DateFormat('yyyy-MM-dd').format(date))
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (snapshot.hasData && snapshot.data!.exists) {
                      Map<String, dynamic> data =
                          snapshot.data!.data() as Map<String, dynamic>;
                      bool allDone =
                          widget.activeTimings.isNotEmpty &&
                          widget.activeTimings.every((t) => data[t] == true);
                      if (allDone) {
                        return const Positioned(
                          bottom: 1,
                          child: Text("💮", style: TextStyle(fontSize: 12)),
                        );
                      }
                    }
                    return const SizedBox();
                  },
                );
              },
            ),
          ),
          const Divider(),
          Expanded(
            child: StreamBuilder<DocumentSnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(widget.userId)
                  .collection('med_logs')
                  .doc(DateFormat('yyyy-MM-dd').format(_selectedDay))
                  .snapshots(),
              builder: (ctx, snp) {
                Map data = snp.hasData && snp.data!.exists
                    ? snp.data!.data() as Map
                    : {};
                if (widget.activeTimings.isEmpty)
                  return const Center(child: Text("設定から時間を追加してください"));
                return ListView(
                  children: widget.activeTimings
                      .map(
                        (t) => Card(
                          child: CheckboxListTile(
                            title: Text("$t の薬"),
                            value: data[t] ?? false,
                            onChanged: (v) {
                              FirebaseFirestore.instance
                                  .collection('users')
                                  .doc(widget.userId)
                                  .collection('med_logs')
                                  .doc(
                                    DateFormat(
                                      'yyyy-MM-dd',
                                    ).format(_selectedDay),
                                  )
                                  .set({t: v}, SetOptions(merge: true));
                            },
                          ),
                        ),
                      )
                      .toList(),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// --- 2. AI栄養 ---
class AIChatPage extends StatefulWidget {
  final String userId;
  const AIChatPage({required this.userId, super.key});
  @override
  State<AIChatPage> createState() => _AIChatPageState();
}

class _AIChatPageState extends State<AIChatPage> {
  final _c = TextEditingController();
  final List<Map<String, String>> _m = [];
  bool _l = false;
  Future<void> _send(String text) async {
    if (text.isEmpty) return;
    setState(() {
      _m.add({"role": "user", "text": text});
      _l = true;
    });
    _c.clear();
    try {
      final model = GenerativeModel(
        model: 'gemini-2.5-flash-lite',
        apiKey: geminiApiKey,
      );
      final res = await model.generateContent([
        Content.text("栄養士として短く助言して: $text"),
      ]);
      setState(() => _m.add({"role": "ai", "text": res.text ?? "..."}));
    } catch (e) {
      setState(() => _m.add({"role": "ai", "text": "エラーです"}));
    } finally {
      setState(() => _l = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("AI健康アドバイザー")),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: _m.length,
              itemBuilder: (ctx, i) => ListTile(
                title: Text(_m[i]["text"]!),
                subtitle: Text(_m[i]["role"] == "user" ? "あなた" : "AI"),
              ),
            ),
          ),
          if (_l) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _c,
                    decoration: const InputDecoration(hintText: "食事内容を入力..."),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: () => _send(_c.text),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// --- 3. 地図機能 ---
class MapPage extends StatefulWidget {
  const MapPage({super.key});
  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final MapController _mapController = MapController();
  LatLng _myLoc = const LatLng(35.6812, 139.7671);
  List<dynamic> _searchResults = [];
  List<Map<String, dynamic>> _favorites = [];
  final _searchController = TextEditingController();
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _loadFavorites();
    _determinePosition();
  }

  Future<void> _loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final fav = prefs.getString('fav_clinics_v3');
    if (fav != null)
      setState(
        () => _favorites = List<Map<String, dynamic>>.from(json.decode(fav)),
      );
  }

  Future<void> _determinePosition() async {
    try {
      Position pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      setState(() {
        _myLoc = LatLng(pos.latitude, pos.longitude);
        _mapController.move(_myLoc, 15);
      });
    } catch (e) {
      print("位置情報エラー: $e");
    }
  }

  Future<void> _search(String query) async {
    if (query.isEmpty) return;
    setState(() => _isSearching = true);
    final url =
        'https://nominatim.openstreetmap.org/search?format=json&q=${Uri.encodeComponent(query)}&lat=${_myLoc.latitude}&lon=${_myLoc.longitude}&viewbox=${_myLoc.longitude - 0.1},${_myLoc.latitude + 0.1},${_myLoc.longitude + 0.1},${_myLoc.latitude - 0.1}';
    try {
      final res = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'HealthBuddyApp/1.0'},
      );
      if (res.statusCode == 200)
        setState(() => _searchResults = json.decode(res.body));
    } finally {
      setState(() => _isSearching = false);
    }
  }

  void _showDetail(dynamic item) {
    bool isFav = _favorites.any((f) => f['osm_id'] == item['osm_id']);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              item['display_name'].split(',')[0],
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      if (isFav)
                        _favorites.removeWhere(
                          (f) => f['osm_id'] == item['osm_id'],
                        );
                      else
                        _favorites.add(item);
                    });
                    SharedPreferences.getInstance().then(
                      (p) => p.setString(
                        'fav_clinics_v3',
                        json.encode(_favorites),
                      ),
                    );
                    Navigator.pop(context);
                  },
                  icon: Icon(
                    isFav ? Icons.favorite : Icons.favorite_border,
                    color: Colors.pink,
                  ),
                  label: Text(isFav ? "解除" : "お気に入り"),
                ),
                ElevatedButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse(
                      "https://www.google.com/search?q=${Uri.encodeComponent(item['display_name'].split(',')[0])}",
                    ),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.language),
                  label: const Text("詳細サイト"),
                ),
              ],
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("病院検索"),
        actions: [
          PopupMenuButton(
            icon: const Icon(Icons.star, color: Colors.orange),
            onSelected: (dynamic f) {
              _mapController.move(
                LatLng(double.parse(f['lat']), double.parse(f['lon'])),
                17,
              );
              _showDetail(f);
            },
            itemBuilder: (ctx) => _favorites.isEmpty
                ? [const PopupMenuItem(child: Text("お気に入りなし"))]
                : _favorites
                      .map(
                        (f) => PopupMenuItem(
                          value: f,
                          child: Text(f['display_name'].split(',')[0]),
                        ),
                      )
                      .toList(),
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(initialCenter: _myLoc, initialZoom: 15),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.healthapp',
              ),
              MarkerLayer(
                markers: [
                  Marker(
                    point: _myLoc,
                    child: const Icon(
                      Icons.person_pin_circle,
                      color: Colors.blue,
                      size: 40,
                    ),
                  ),
                  ..._searchResults.map(
                    (item) => Marker(
                      point: LatLng(
                        double.parse(item['lat']),
                        double.parse(item['lon']),
                      ),
                      child: IconButton(
                        icon: const Icon(
                          Icons.location_on,
                          color: Colors.red,
                          size: 40,
                        ),
                        onPressed: () => _showDetail(item),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          Positioned(
            top: 10,
            left: 10,
            right: 10,
            child: Card(
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: "例: 皮膚科, 薬局",
                  border: InputBorder.none,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _isSearching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton(
                          icon: const Icon(Icons.send),
                          onPressed: () => _search(_searchController.text),
                        ),
                ),
                onSubmitted: (v) => _search(v),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// --- 4. 設定画面 (テストボタン整理版) ---
class SettingsPage extends StatefulWidget {
  final List<String> initialTimes;
  final bool initialNotif;
  final Function(List<String>, bool) onSave;
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
  @override
  void initState() {
    super.initState();
    _times = List.from(widget.initialTimes);
    _notif = widget.initialNotif;
  }

  // ★即時テスト通知 (お薬を飲む時間です！)
  Future<void> _showImmediateNotification() async {
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'high_importance_channel',
          '服薬・健康通知',
          importance: Importance.max,
          priority: Priority.high,
          fullScreenIntent: true,
        );
    const NotificationDetails platformDetails = NotificationDetails(
      android: androidDetails,
    );
    await flutterLocalNotificationsPlugin.show(
      123,
      'お薬を飲む時間です！',
      'お薬を飲んで、記録をつけましょう。',
      platformDetails,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("設定")),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            title: const Text("通知を有効にする"),
            value: _notif,
            onChanged: (v) => setState(() => _notif = v),
          ),
          Card(
            color: Colors.teal[50],
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                children: [
                  const Text(
                    "通知テスト",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton.icon(
                    onPressed: _showImmediateNotification,
                    icon: const Icon(Icons.notifications_active),
                    label: const Text("今すぐ通知を出す"),
                  ),
                  const Text("", style: TextStyle(fontSize: 11)),
                ],
              ),
            ),
          ),
          const Divider(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("服薬スケジュール"),
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: () async {
                  final p = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay.now(),
                  );
                  if (p != null)
                    setState(() {
                      _times.add(
                        "${p.hour.toString().padLeft(2, '0')}:${p.minute.toString().padLeft(2, '0')}",
                      );
                      _times.sort();
                    });
                },
              ),
            ],
          ),
          ..._times.map(
            (t) => ListTile(
              title: Text(t),
              trailing: IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () => setState(() => _times.remove(t)),
              ),
            ),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: () => widget.onSave(_times, _notif),
            child: const Text("設定を保存"),
          ),
        ],
      ),
    );
  }
}
