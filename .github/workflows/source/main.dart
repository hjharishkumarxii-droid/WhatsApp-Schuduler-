import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';

final plugin = FlutterLocalNotificationsPlugin();
const green = Color(0xFF128C7E);

// ---------- WhatsApp ----------
Future<void> sendWa(String number, String text) async {
  final digits = number.replaceAll(RegExp(r'[^0-9]'), '');
  final uri =
      Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(text)}');
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

Future<void> onTapNotification(String? payload) async {
  if (payload == null) return;
  final d = jsonDecode(payload);
  await sendWa(d['n'], d['t']);
}

// ---------- Model ----------
class Msg {
  int id;
  String name, number, text, repeat, remind;
  DateTime when;
  String? mediaPath;

  Msg(this.id, this.name, this.number, this.text, this.when, this.repeat,
      this.remind, this.mediaPath);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'number': number,
        'text': text,
        'when': when.toIso8601String(),
        'repeat': repeat,
        'remind': remind,
        'media': mediaPath,
      };

  factory Msg.fromJson(Map<String, dynamic> j) => Msg(
        j['id'],
        j['name'],
        j['number'],
        j['text'],
        DateTime.parse(j['when']),
        j['repeat'],
        j['remind'],
        j['media'],
      );
}

// ---------- Storage ----------
Future<List<Msg>> loadMsgs() async {
  final sp = await SharedPreferences.getInstance();
  final raw = sp.getString('msgs');
  if (raw == null) return [];
  return (jsonDecode(raw) as List).map((e) => Msg.fromJson(e)).toList();
}

Future<void> saveMsgs(List<Msg> list) async {
  final sp = await SharedPreferences.getInstance();
  await sp.setString('msgs', jsonEncode(list.map((e) => e.toJson()).toList()));
}

// ---------- Reminder scheduling ----------
Future<void> scheduleReminder(Msg m) async {
  final isAlarm = m.remind == 'Alarm';
  final details = NotificationDetails(
    android: AndroidNotificationDetails(
      isAlarm ? 'alarm_channel' : 'reminder_channel',
      isAlarm ? 'Alarm' : 'Reminder',
      importance: Importance.max,
      priority: Priority.high,
      category: isAlarm ? AndroidNotificationCategory.alarm : null,
      fullScreenIntent: isAlarm,
      audioAttributesUsage:
          isAlarm ? AudioAttributesUsage.alarm : AudioAttributesUsage.notification,
      ongoing: isAlarm,
      autoCancel: !isAlarm,
      // 4 = FLAG_INSISTENT: sound repeats until user reacts
      additionalFlags: isAlarm ? Int32List.fromList([4]) : null,
    ),
    iOS: const DarwinNotificationDetails(presentSound: true),
  );

  DateTimeComponents? match;
  if (m.repeat == 'Daily') match = DateTimeComponents.time;
  if (m.repeat == 'Weekly') match = DateTimeComponents.dayOfWeekAndTime;
  if (m.repeat == 'Monthly') match = DateTimeComponents.dayOfMonthAndTime;

  await plugin.zonedSchedule(
    m.id,
    'WhatsApp bhejna hai: ${m.name}',
    m.text,
    tz.TZDateTime.from(m.when, tz.local),
    details,
    androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    uiLocalNotificationDateInterpretation:
        UILocalNotificationDateInterpretation.absoluteTime,
    matchDateTimeComponents: match,
    payload: jsonEncode({'n': m.number, 't': m.text}),
  );
}

// ---------- App ----------
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  final zone = await FlutterTimezone.getLocalTimezone();
  tz.setLocalLocation(tz.getLocation(zone));

  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    ),
    onDidReceiveNotificationResponse: (r) => onTapNotification(r.payload),
  );

  final android = plugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await android?.requestNotificationsPermission();
  await android?.requestExactAlarmsPermission();

  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'WhatsApp Scheduler',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: green),
          useMaterial3: true,
        ),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Msg> msgs = [];

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    final l = await loadMsgs();
    l.sort((a, b) => a.when.compareTo(b.when));
    setState(() => msgs = l);
  }

  Future<void> remove(Msg m) async {
    await plugin.cancel(m.id);
    if (m.mediaPath != null) {
      final f = File(m.mediaPath!);
      if (await f.exists()) await f.delete();
    }
    msgs.removeWhere((e) => e.id == m.id);
    await saveMsgs(msgs);
    setState(() {});
  }

  String fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}  '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WhatsApp Scheduler'),
        backgroundColor: green,
        foregroundColor: Colors.white,
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: green,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Naya Message'),
        onPressed: () async {
          await Navigator.push(context,
              MaterialPageRoute(builder: (_) => const AddPage()));
          refresh();
        },
      ),
      body: msgs.isEmpty
          ? const Center(child: Text('Abhi koi message schedule nahi hai'))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: msgs.length,
              itemBuilder: (_, i) {
                final m = msgs[i];
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(m.name,
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold)),
                        Text(m.number),
                        const SizedBox(height: 6),
                        Text(m.text),
                        const SizedBox(height: 6),
                        Text('${fmt(m.when)}  •  ${m.repeat}  •  ${m.remind}',
                            style: const TextStyle(color: Colors.black54)),
                        if (m.mediaPath != null)
                          Text('Media: ${p.basename(m.mediaPath!)}',
                              style: const TextStyle(color: Colors.black54)),
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, children: [
                          FilledButton.icon(
                            style: FilledButton.styleFrom(backgroundColor: green),
                            onPressed: () => sendWa(m.number, m.text),
                            icon: const Icon(Icons.send),
                            label: const Text('WhatsApp pe bhejo'),
                          ),
                          if (m.mediaPath != null)
                            OutlinedButton.icon(
                              onPressed: () => Share.shareXFiles(
                                  [XFile(m.mediaPath!)],
                                  text: m.text),
                              icon: const Icon(Icons.attach_file),
                              label: const Text('Media bhejo'),
                            ),
                          IconButton(
                            onPressed: () => remove(m),
                            icon: const Icon(Icons.delete, color: Colors.red),
                          ),
                        ]),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class AddPage extends StatefulWidget {
  const AddPage({super.key});
  @override
  State<AddPage> createState() => _AddPageState();
}

class _AddPageState extends State<AddPage> {
  final name = TextEditingController();
  final number = TextEditingController(text: '91');
  final text = TextEditingController();
  DateTime? date;
  TimeOfDay? time;
  String repeat = 'Once';
  String remind = 'Notification';
  String? media;

  Future<void> pickMedia() async {
    final r = await FilePicker.platform.pickFiles();
    final path = r?.files.single.path;
    if (path == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final dest = p.join(dir.path,
        '${DateTime.now().millisecondsSinceEpoch}_${r!.files.single.name}');
    await File(path).copy(dest);
    setState(() => media = dest);
  }

  Future<void> save() async {
    if (name.text.trim().isEmpty ||
        number.text.trim().isEmpty ||
        date == null ||
        time == null) {
      _snack('Naam, number, date aur time bharo');
      return;
    }
    if (text.text.trim().isEmpty && media == null) {
      _snack('Message likho ya media lagao');
      return;
    }
    final when =
        DateTime(date!.year, date!.month, date!.day, time!.hour, time!.minute);
    if (repeat == 'Once' && when.isBefore(DateTime.now())) {
      _snack('Time aage ka chuno');
      return;
    }
    final m = Msg(
      DateTime.now().millisecondsSinceEpoch % 2147483647,
      name.text.trim(),
      number.text.trim(),
      text.text.trim(),
      when,
      repeat,
      remind,
      media,
    );
    final list = await loadMsgs();
    list.add(m);
    await saveMsgs(list);
    await scheduleReminder(m);
    if (mounted) Navigator.pop(context);
  }

  void _snack(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Naya Message Schedule Karein'),
        backgroundColor: green,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Naam')),
          TextField(
              controller: number,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                  labelText: 'WhatsApp number (country code ke sath)')),
          TextField(
              controller: text,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Message')),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today),
                label: Text(date == null
                    ? 'Date chuno'
                    : '${date!.day}/${date!.month}/${date!.year}'),
                onPressed: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: DateTime.now(),
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 3650)),
                  );
                  if (d != null) setState(() => date = d);
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.access_time),
                label: Text(time == null ? 'Time chuno' : time!.format(context)),
                onPressed: () async {
                  final t = await showTimePicker(
                      context: context, initialTime: TimeOfDay.now());
                  if (t != null) setState(() => time = t);
                },
              ),
            ),
          ]),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: repeat,
            decoration: const InputDecoration(labelText: 'Repeat'),
            items: ['Once', 'Daily', 'Weekly', 'Monthly']
                .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                .toList(),
            onChanged: (v) => setState(() => repeat = v!),
          ),
          DropdownButtonFormField<String>(
            value: remind,
            decoration: const InputDecoration(labelText: 'Reminder type'),
            items: ['Notification', 'Alarm']
                .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                .toList(),
            onChanged: (v) => setState(() => remind = v!),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.attach_file),
            label: Text(media == null
                ? 'Media lagao (photo / video / file)'
                : p.basename(media!)),
            onPressed: pickMedia,
          ),
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: green, padding: const EdgeInsets.all(14)),
            onPressed: save,
            child: const Text('Schedule Karo', style: TextStyle(fontSize: 16)),
          ),
          const SizedBox(height: 12),
          const Text(
            'Dhyan rakhein: WhatsApp apne aap message nahi bhejta. Time pe reminder aayega, '
            'usse tap karo, WhatsApp khulega aur aapko bas Send dabana hai.',
            style: TextStyle(color: Colors.black54),
          ),
        ],
      ),
    );
  }
}
