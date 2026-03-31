import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as p;
import 'package:intl/intl.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

void main() {
  runApp(const SyncApp());
}

class SyncApp extends StatelessWidget {
  const SyncApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '手机文件同步',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1D9E75)),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

// ─── 数据模型 ────────────────────────────────────────────────
class SyncDir {
  String path;
  bool enabled;
  SyncDir({required this.path, this.enabled = true});
  Map<String, dynamic> toJson() => {'path': path, 'enabled': enabled};
  factory SyncDir.fromJson(Map<String, dynamic> j) =>
      SyncDir(path: j['path'], enabled: j['enabled'] ?? true);
}

class SyncHistory {
  final DateTime time;
  final int transferred;
  final int skipped;
  final String status;
  SyncHistory({required this.time, required this.transferred, required this.skipped, required this.status});
  Map<String, dynamic> toJson() => {
    'time': time.toIso8601String(),
    'transferred': transferred,
    'skipped': skipped,
    'status': status,
  };
  factory SyncHistory.fromJson(Map<String, dynamic> j) => SyncHistory(
    time: DateTime.parse(j['time']),
    transferred: j['transferred'] ?? 0,
    skipped: j['skipped'] ?? 0,
    status: j['status'] ?? '',
  );
}

// ─── 主页面 ──────────────────────────────────────────────────
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // 设置
  String _serverIp = '';
  String _serverPort = '5678';
  List<SyncDir> _dirs = [];
  DateTime? _sinceDate;
  bool _autoSync = false;

  // 状态
  bool _syncing = false;
  bool _connected = false;
  int _progress = 0;
  int _progressTotal = 0;
  List<String> _logs = [];
  List<SyncHistory> _history = [];

  final _ipController = TextEditingController();
  final _portController = TextEditingController(text: '5678');

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _listenConnectivity();
  }

  void _listenConnectivity() {
    Connectivity().onConnectivityChanged.listen((result) {
      if (result == ConnectivityResult.wifi && _autoSync && !_syncing) {
        _log('检测到WiFi连接，自动开始同步...');
        Future.delayed(const Duration(seconds: 3), _startSync);
      }
    });
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _serverIp = prefs.getString('server_ip') ?? '';
      _serverPort = prefs.getString('server_port') ?? '5678';
      _autoSync = prefs.getBool('auto_sync') ?? false;
      _ipController.text = _serverIp;
      _portController.text = _serverPort;

      final dirsJson = prefs.getStringList('sync_dirs') ?? [];
      _dirs = dirsJson.map((s) => SyncDir.fromJson(jsonDecode(s))).toList();

      final since = prefs.getString('since_date');
      if (since != null) _sinceDate = DateTime.tryParse(since);

      final histJson = prefs.getStringList('history') ?? [];
      _history = histJson.map((s) => SyncHistory.fromJson(jsonDecode(s))).toList();
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_ip', _serverIp);
    await prefs.setString('server_port', _serverPort);
    await prefs.setBool('auto_sync', _autoSync);
    await prefs.setStringList('sync_dirs', _dirs.map((d) => jsonEncode(d.toJson())).toList());
    if (_sinceDate != null) {
      await prefs.setString('since_date', _sinceDate!.toIso8601String());
    }
    await prefs.setStringList('history', _history.map((h) => jsonEncode(h.toJson())).toList());
  }

  void _log(String msg) {
    final now = DateFormat('HH:mm:ss').format(DateTime.now());
    setState(() {
      _logs.insert(0, '[$now] $msg');
      if (_logs.length > 200) _logs.removeLast();
    });
  }

  String get _baseUrl => 'http://$_serverIp:$_serverPort';

  Future<void> _testConnection() async {
    if (_serverIp.isEmpty) {
      _showSnack('请先输入电脑IP地址');
      return;
    }
    try {
      final res = await http.get(Uri.parse('$_baseUrl/ping')).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        setState(() => _connected = true);
        _log('连接成功：$_serverIp:$_serverPort');
        _showSnack('连接成功！');
      } else {
        setState(() => _connected = false);
        _log('连接失败：状态码 ${res.statusCode}');
      }
    } catch (e) {
      setState(() => _connected = false);
      _log('连接失败：$e');
      _showSnack('连接失败，请检查IP和电脑服务是否启动');
    }
  }

  Future<void> _requestPermissions() async {
    await Permission.storage.request();
    await Permission.manageExternalStorage.request();
  }

  Future<void> _addDir() async {
    await _requestPermissions();
    final controller = TextEditingController(text: '/storage/emulated/0/DCIM/Camera');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加同步目录'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: '目录路径',
            hintText: '/storage/emulated/0/DCIM/Camera',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      setState(() => _dirs.add(SyncDir(path: result)));
      await _savePrefs();
    }
  }

  Future<void> _startSync() async {
    if (_syncing) return;
    if (_serverIp.isEmpty) { _showSnack('请先设置电脑IP'); return; }
    if (_dirs.isEmpty) { _showSnack('请先添加同步目录'); return; }

    await _requestPermissions();
    setState(() {
      _syncing = true;
      _progress = 0;
      _progressTotal = 0;
    });
    _log('开始同步...');

    int totalTransferred = 0;
    int totalSkipped = 0;
    String finalStatus = '成功';

    try {
      for (final dir in _dirs.where((d) => d.enabled)) {
        _log('扫描目录：${dir.path}');
        final directory = Directory(dir.path);
        if (!await directory.exists()) {
          _log('目录不存在，跳过：${dir.path}');
          continue;
        }

        // 扫描文件
        final allFiles = <Map<String, dynamic>>[];
        await for (final entity in directory.list(recursive: true)) {
          if (entity is File) {
            final stat = await entity.stat();
            // 时间过滤
            if (_sinceDate != null && stat.modified.isBefore(_sinceDate!)) continue;
            final relativeName = p.relative(entity.path, from: dir.path);
            allFiles.add({
              'name': relativeName,
              'size': stat.size,
              'mtime': stat.modified.millisecondsSinceEpoch ~/ 1000,
            });
          }
        }

        _log('发现 ${allFiles.length} 个文件');
        if (allFiles.isEmpty) continue;

        // 检查哪些文件需要传输
        final checkRes = await http.post(
          Uri.parse('$_baseUrl/check_files'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'files': allFiles}),
        ).timeout(const Duration(seconds: 30));

        final checkData = jsonDecode(checkRes.body);
        final needed = List<String>.from(checkData['need_transfer'] ?? []);
        final skipped = allFiles.length - needed.length;
        totalSkipped += skipped;
        _log('需传输 ${needed.length} 个，跳过已存在 $skipped 个');

        setState(() => _progressTotal = needed.length);

        // 逐个上传
        for (int i = 0; i < needed.length; i++) {
          if (!_syncing) break;
          final filename = needed[i];
          final filePath = p.join(dir.path, filename);
          _log('传输 (${i+1}/${needed.length}): $filename');

          try {
            final request = http.MultipartRequest('POST', Uri.parse('$_baseUrl/upload'));
            request.files.add(await http.MultipartFile.fromPath('file', filePath));
            request.fields['filename'] = filename;
            request.fields['total'] = needed.length.toString();
            request.fields['index'] = (i + 1).toString();

            final response = await request.send().timeout(const Duration(seconds: 60));
            if (response.statusCode == 200) {
              totalTransferred++;
              setState(() => _progress = i + 1);
            } else {
              _log('上传失败：$filename (${response.statusCode})');
            }
          } catch (e) {
            _log('上传出错：$filename - $e');
          }
        }
      }

      // 通知完成
      await http.post(
        Uri.parse('$_baseUrl/sync_done'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'total': totalTransferred + totalSkipped, 'transferred': totalTransferred}),
      );

      _log('同步完成！传输 $totalTransferred 个，跳过 $totalSkipped 个');
    } catch (e) {
      _log('同步出错：$e');
      finalStatus = '失败';
    }

    // 保存历史
    _history.insert(0, SyncHistory(
      time: DateTime.now(),
      transferred: totalTransferred,
      skipped: totalSkipped,
      status: finalStatus,
    ));
    if (_history.length > 50) _history.removeLast();

    setState(() => _syncing = false);
    await _savePrefs();
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('手机文件同步'),
          backgroundColor: const Color(0xFF1D9E75),
          foregroundColor: Colors.white,
          bottom: const TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.white,
            tabs: [
              Tab(text: '同步', icon: Icon(Icons.sync, size: 18)),
              Tab(text: '目录', icon: Icon(Icons.folder, size: 18)),
              Tab(text: '历史', icon: Icon(Icons.history, size: 18)),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildSyncTab(),
            _buildDirsTab(),
            _buildHistoryTab(),
          ],
        ),
      ),
    );
  }

  // ── 同步页 ──
  Widget _buildSyncTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 连接设置
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.computer, color: _connected ? const Color(0xFF1D9E75) : Colors.grey),
                  const SizedBox(width: 8),
                  Text('电脑连接', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _connected ? const Color(0xFFE1F5EE) : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _connected ? '已连接' : '未连接',
                      style: TextStyle(
                        fontSize: 12,
                        color: _connected ? const Color(0xFF1D9E75) : Colors.grey,
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _ipController,
                      decoration: const InputDecoration(
                        labelText: '电脑IP地址',
                        hintText: '192.168.0.107',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (v) { _serverIp = v; _savePrefs(); },
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 1,
                    child: TextField(
                      controller: _portController,
                      decoration: const InputDecoration(
                        labelText: '端口',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (v) { _serverPort = v; _savePrefs(); },
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _testConnection,
                    icon: const Icon(Icons.wifi_tethering),
                    label: const Text('测试连接'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // 时间筛选
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.calendar_today, color: Color(0xFF1D9E75)),
                  const SizedBox(width: 8),
                  Text('时间筛选', style: Theme.of(context).textTheme.titleMedium),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: Text(
                      _sinceDate == null
                          ? '同步全部文件'
                          : '同步 ${DateFormat('yyyy-MM-dd').format(_sinceDate!)} 之后的文件',
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _sinceDate ?? DateTime.now(),
                        firstDate: DateTime(2010),
                        lastDate: DateTime.now(),
                      );
                      if (picked != null) {
                        setState(() => _sinceDate = picked);
                        _savePrefs();
                      }
                    },
                    child: const Text('选择日期'),
                  ),
                  if (_sinceDate != null)
                    TextButton(
                      onPressed: () { setState(() => _sinceDate = null); _savePrefs(); },
                      child: const Text('清除', style: TextStyle(color: Colors.red)),
                    ),
                ]),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // 自动同步
        Card(
          child: SwitchListTile(
            title: const Text('连上WiFi自动同步'),
            subtitle: const Text('连接WiFi后自动开始同步'),
            value: _autoSync,
            activeColor: const Color(0xFF1D9E75),
            onChanged: (v) { setState(() => _autoSync = v); _savePrefs(); },
          ),
        ),
        const SizedBox(height: 12),

        // 进度
        if (_syncing || _progressTotal > 0)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('同步进度', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: _progressTotal > 0 ? _progress / _progressTotal : null,
                    backgroundColor: Colors.grey.shade200,
                    color: const Color(0xFF1D9E75),
                    minHeight: 8,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _progressTotal > 0 ? '$_progress / $_progressTotal 个文件' : '准备中...',
                    style: const TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),

        const SizedBox(height: 12),

        // 开始按钮
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: _syncing ? null : _startSync,
            icon: _syncing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.sync),
            label: Text(_syncing ? '同步中...' : '开始同步'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF1D9E75),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
        if (_syncing)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SizedBox(
              height: 44,
              child: OutlinedButton.icon(
                onPressed: () => setState(() => _syncing = false),
                icon: const Icon(Icons.stop, color: Colors.red),
                label: const Text('停止', style: TextStyle(color: Colors.red)),
              ),
            ),
          ),

        const SizedBox(height: 16),

        // 日志
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.all(12),
          height: 220,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Text('日志', style: TextStyle(color: Colors.white70, fontSize: 13)),
                const Spacer(),
                GestureDetector(
                  onTap: () => setState(() => _logs.clear()),
                  child: const Text('清空', style: TextStyle(color: Colors.grey, fontSize: 12)),
                ),
              ]),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  reverse: false,
                  itemCount: _logs.length,
                  itemBuilder: (ctx, i) => Text(
                    _logs[i],
                    style: const TextStyle(color: Color(0xFFD4D4D4), fontSize: 11, fontFamily: 'monospace'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── 目录页 ──
  Widget _buildDirsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ..._dirs.map((dir) => Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: const Icon(Icons.folder, color: Color(0xFF1D9E75)),
            title: Text(p.basename(dir.path), style: const TextStyle(fontWeight: FontWeight.w500)),
            subtitle: Text(dir.path, style: const TextStyle(fontSize: 12)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: dir.enabled,
                  activeColor: const Color(0xFF1D9E75),
                  onChanged: (v) { setState(() => dir.enabled = v); _savePrefs(); },
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  onPressed: () {
                    setState(() => _dirs.remove(dir));
                    _savePrefs();
                  },
                ),
              ],
            ),
          ),
        )),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _addDir,
          icon: const Icon(Icons.add),
          label: const Text('添加目录'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(double.infinity, 48),
          ),
        ),
        const SizedBox(height: 16),
        const Text('常用路径', style: TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 8),
        ...[
          '/storage/emulated/0/DCIM/Camera',
          '/storage/emulated/0/DCIM/Screenshots',
          '/storage/emulated/0/Pictures',
          '/storage/emulated/0/Download',
        ].map((path) => ListTile(
          dense: true,
          leading: const Icon(Icons.folder_outlined, size: 20, color: Colors.grey),
          title: Text(path, style: const TextStyle(fontSize: 13)),
          trailing: TextButton(
            onPressed: () {
              if (!_dirs.any((d) => d.path == path)) {
                setState(() => _dirs.add(SyncDir(path: path)));
                _savePrefs();
              } else {
                _showSnack('该目录已添加');
              }
            },
            child: const Text('添加'),
          ),
        )),
      ],
    );
  }

  // ── 历史页 ──
  Widget _buildHistoryTab() {
    if (_history.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('暂无同步记录', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _history.length,
      itemBuilder: (ctx, i) {
        final h = _history[i];
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: h.status == '成功' ? const Color(0xFFE1F5EE) : Colors.red.shade50,
              child: Icon(
                h.status == '成功' ? Icons.check : Icons.error_outline,
                color: h.status == '成功' ? const Color(0xFF1D9E75) : Colors.red,
                size: 20,
              ),
            ),
            title: Text(DateFormat('yyyy-MM-dd HH:mm').format(h.time)),
            subtitle: Text('传输 ${h.transferred} 个，跳过 ${h.skipped} 个'),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: h.status == '成功' ? const Color(0xFFE1F5EE) : Colors.red.shade50,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                h.status,
                style: TextStyle(
                  fontSize: 12,
                  color: h.status == '成功' ? const Color(0xFF1D9E75) : Colors.red,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
