import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:openrig_core/openrig_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/settings_service.dart';

enum _RowAction { edit, qrzLookup, openQrzPage, delete }

class LogScreen extends StatefulWidget {
  final String logPath;
  final SettingsService settings;

  const LogScreen({super.key, required this.logPath, required this.settings});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

const _modeOptions = ['All', 'USB', 'LSB', 'CW', 'FM', 'AM', 'DIGI'];

class _LogScreenState extends State<LogScreen> {
  List<QsoRecord> _records = [];
  bool _loaded = false;
  bool _uploading = false;

  // Filter state
  final _searchCtl = TextEditingController();
  String? _bandFilter;
  String? _modeFilter;

  @override
  void initState() {
    super.initState();
    _searchCtl.addListener(_onFilterChanged);
    _loadLog();
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  void _onFilterChanged() {
    setState(() {});
  }

  List<QsoRecord> get _filteredRecords {
    final hasCallFilter = _searchCtl.text.trim().isNotEmpty;
    if (!hasCallFilter && _bandFilter == null && _modeFilter == null) {
      return _records;
    }
    return LogSearch.filter(
      _records,
      callsign: hasCallFilter ? _searchCtl.text.trim() : null,
      band: _bandFilter,
      mode: _modeFilter,
    );
  }

  void _clearFilters() {
    _searchCtl.clear();
    setState(() {
      _bandFilter = null;
      _modeFilter = null;
    });
  }

  bool get _hasFilters =>
      _searchCtl.text.trim().isNotEmpty ||
      _bandFilter != null ||
      _modeFilter != null;

  Future<void> _exportAdif() async {
    final records = _filteredRecords;
    if (records.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No QSOs to export')),
        );
      }
      return;
    }

    final now = DateTime.now();
    final defaultName = 'openrig_export_'
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
        '.adi';

    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export ADIF',
        fileName: defaultName,
        type: FileType.any,
      );
      if (path == null) return;

      final content = AdifLog.encode(records);
      await File(path).writeAsString(content);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported ${records.length} QSOs')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }

  Future<void> _importAdif() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Import ADIF',
        type: FileType.any,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      final path = result.files.single.path;
      if (path == null) return;

      final content = await File(path).readAsString();
      final imported = AdifLog.parse(content);
      if (imported.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No QSOs found in file')),
          );
        }
        return;
      }

      // Merge: append imported records that aren't already in the log.
      // De-duplicate by call + timeOn.
      final existingKeys = _records
          .map((r) => '${r.call}|${r.timeOn.toIso8601String()}')
          .toSet();
      final newOnes = imported
          .where((r) =>
              !existingKeys.contains('${r.call}|${r.timeOn.toIso8601String()}'))
          .toList();

      // Merge and re-sort newest-first.
      final merged = [..._records, ...newOnes]
        ..sort((a, b) => b.timeOn.compareTo(a.timeOn));

      final out = AdifLog.encode(merged.reversed.toList());
      await File(widget.logPath).writeAsString(out);
      setState(() => _records = merged);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              newOnes.isEmpty
                  ? 'All ${imported.length} QSOs already in log'
                  : 'Imported ${newOnes.length} new QSO${newOnes.length == 1 ? '' : 's'}'
                      ' (${imported.length - newOnes.length} duplicates skipped)',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e')),
        );
      }
    }
  }

  Future<void> _uploadToQrz() async {
    final apiKey = widget.settings.qrzApiKey;
    if (apiKey.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Add your QRZ API key in Preferences')),
        );
      }
      return;
    }

    final records = _filteredRecords;
    if (records.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No QSOs to upload')),
        );
      }
      return;
    }

    setState(() => _uploading = true);
    try {
      final client = QrzLogbookClient(apiKey: apiKey);
      final results = await client.insertQsos(records);
      client.dispose();
      final succeeded = results.where((r) => r.success).length;
      final failed = results.length - succeeded;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Uploaded $succeeded QSOs to QRZ ($failed failed)'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('QRZ upload failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _loadLog() async {
    final file = File(widget.logPath);
    if (await file.exists()) {
      final content = await file.readAsString();
      setState(() {
        _records = AdifLog.parse(content).reversed.toList();
        _loaded = true;
      });
    } else {
      setState(() => _loaded = true);
    }
  }

  void _showAddQsoDialog() {
    final callCtl = TextEditingController();
    final freqCtl = TextEditingController();
    final modeCtl = TextEditingController(text: 'SSB');
    final rstSentCtl = TextEditingController(text: '59');
    final rstRcvdCtl = TextEditingController(text: '59');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New QSO'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: callCtl,
              decoration: const InputDecoration(labelText: 'Callsign'),
              textCapitalization: TextCapitalization.characters,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: freqCtl,
              decoration: const InputDecoration(labelText: 'Frequency (MHz)'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: modeCtl,
              decoration: const InputDecoration(labelText: 'Mode'),
              textCapitalization: TextCapitalization.characters,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: rstSentCtl,
              decoration: const InputDecoration(labelText: 'RST Sent'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: rstRcvdCtl,
              decoration: const InputDecoration(labelText: 'RST Received'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final call = callCtl.text.trim().toUpperCase();
              final freq = double.tryParse(freqCtl.text.trim());
              final mode = modeCtl.text.trim().toUpperCase();
              if (call.isEmpty || freq == null || mode.isEmpty) return;

              final record = QsoRecord(
                call: call,
                band: _freqToBand(freq),
                mode: mode,
                freqMhz: freq,
                timeOn: DateTime.now().toUtc(),
                rstSent: rstSentCtl.text.trim(),
                rstRcvd: rstRcvdCtl.text.trim(),
              );

              await AdifLog.appendRecord(widget.logPath, record);
              if (ctx.mounted) Navigator.of(ctx).pop();
              if (mounted) setState(() => _records.insert(0, record));
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _qrzLookup(int index, QsoRecord q) async {
    final user = widget.settings.qrzXmlUser;
    final pass = widget.settings.qrzXmlPass;
    if (user.isEmpty || pass.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Add QRZ XML credentials in Preferences')),
        );
      }
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Looking up ${q.call}…')),
      );
    }
    try {
      final client = QrzXmlClient(username: user, password: pass);
      final info = await client.lookupCallsign(q.call);
      client.dispose();
      if (!mounted) return;

      final extra = Map<String, String>.from(q.extra);
      if (info.city.isNotEmpty)    { extra['QTH']     = info.city; }
      if (info.state.isNotEmpty)   { extra['STATE']   = info.state; }
      if (info.country.isNotEmpty) { extra['COUNTRY'] = info.country; }

      final updated = QsoRecord(
        call:       q.call,
        band:       q.band,
        mode:       q.mode,
        freqMhz:    q.freqMhz,
        timeOn:     q.timeOn,
        timeOff:    q.timeOff,
        rstSent:    q.rstSent,
        rstRcvd:    q.rstRcvd,
        name:       info.fullName.isNotEmpty ? info.fullName : q.name,
        gridsquare: info.grid.isNotEmpty ? info.grid : q.gridsquare,
        comment:    q.comment,
        mySotaRef:  q.mySotaRef,
        sotaRef:    q.sotaRef,
        myPotaRef:  q.myPotaRef,
        potaRef:    q.potaRef,
        extra:      extra,
      );

      final newRecords = List<QsoRecord>.from(_records);
      newRecords[index] = updated;
      final content = AdifLog.encode(newRecords.reversed.toList());
      await File(widget.logPath).writeAsString(content);
      setState(() => _records = newRecords);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Updated ${q.call} from QRZ')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('QRZ lookup failed: $e')),
        );
      }
    }
  }

  void _showRowMenu(BuildContext context, Offset position,
      int recordIdx, QsoRecord q) async {
    final result = await showMenu<_RowAction>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, position.dx + 1, position.dy + 1),
      items: [
        const PopupMenuItem(
          value: _RowAction.edit,
          child: Row(children: [
            Icon(Icons.edit, size: 16),
            SizedBox(width: 8),
            Text('Edit'),
          ]),
        ),
        const PopupMenuItem(
          value: _RowAction.qrzLookup,
          child: Row(children: [
            Icon(Icons.search, size: 16),
            SizedBox(width: 8),
            Text('Update from QRZ'),
          ]),
        ),
        const PopupMenuItem(
          value: _RowAction.openQrzPage,
          child: Row(children: [
            Icon(Icons.open_in_browser, size: 16),
            SizedBox(width: 8),
            Text('Open QRZ Page'),
          ]),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _RowAction.delete,
          child: Row(children: [
            Icon(Icons.delete, size: 16, color: Colors.red.shade300),
            const SizedBox(width: 8),
            Text('Delete', style: TextStyle(color: Colors.red.shade300)),
          ]),
        ),
      ],
    );
    if (!mounted) return;
    switch (result) {
      case _RowAction.edit:
        _editQso(recordIdx, q);
      case _RowAction.qrzLookup:
        _qrzLookup(recordIdx, q);
      case _RowAction.openQrzPage:
        launchUrl(
          Uri.parse('https://www.qrz.com/db/${q.call}'),
          mode: LaunchMode.externalApplication,
        );
      case _RowAction.delete:
        _deleteQso(recordIdx, q);
      case null:
        break;
    }
  }

  Future<void> _deleteQso(int index, QsoRecord q) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete QSO'),
        content: Text('Delete QSO with ${q.call}? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final newRecords = List<QsoRecord>.from(_records)..removeAt(index);
    final content = AdifLog.encode(newRecords.reversed.toList());
    await File(widget.logPath).writeAsString(content);
    setState(() => _records = newRecords);
  }

  Future<void> _editQso(int index, QsoRecord q) async {
    final callCtl   = TextEditingController(text: q.call);
    final freqCtl   = TextEditingController(text: q.freqMhz.toStringAsFixed(6));
    final modeCtl   = TextEditingController(text: q.mode);
    final rstSCtl   = TextEditingController(text: q.rstSent ?? '');
    final rstRCtl   = TextEditingController(text: q.rstRcvd ?? '');
    final nameCtl   = TextEditingController(text: q.name ?? '');
    final cityCtl   = TextEditingController(text: q.extra['QTH'] ?? '');
    final stateCtl  = TextEditingController(text: q.extra['STATE'] ?? '');
    final countryCtl= TextEditingController(text: q.extra['COUNTRY'] ?? '');
    final commentCtl= TextEditingController(text: q.comment ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Edit QSO — ${q.call}'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _editField(callCtl, 'Callsign',
                    caps: TextCapitalization.characters),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: _editField(freqCtl, 'Freq (MHz)',
                      keyboard: TextInputType.number)),
                  const SizedBox(width: 8),
                  Expanded(child: _editField(modeCtl, 'Mode',
                      caps: TextCapitalization.characters)),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: _editField(rstSCtl, 'RST Sent')),
                  const SizedBox(width: 8),
                  Expanded(child: _editField(rstRCtl, 'RST Rcvd')),
                ]),
                const SizedBox(height: 8),
                _editField(nameCtl, 'Name'),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(flex: 2, child: _editField(cityCtl, 'City')),
                  const SizedBox(width: 8),
                  Expanded(child: _editField(stateCtl, 'State',
                      caps: TextCapitalization.characters)),
                ]),
                const SizedBox(height: 8),
                _editField(countryCtl, 'Country'),
                const SizedBox(height: 8),
                _editField(commentCtl, 'Comments', maxLines: 3),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (saved != true || !mounted) return;

    final freq = double.tryParse(freqCtl.text.trim()) ?? q.freqMhz;
    final extra = Map<String, String>.from(q.extra);
    final city    = cityCtl.text.trim();
    final state   = stateCtl.text.trim();
    final country = countryCtl.text.trim();
    if (city.isNotEmpty)    { extra['QTH']     = city; }    else { extra.remove('QTH'); }
    if (state.isNotEmpty)   { extra['STATE']   = state; }   else { extra.remove('STATE'); }
    if (country.isNotEmpty) { extra['COUNTRY'] = country; } else { extra.remove('COUNTRY'); }

    final updated = QsoRecord(
      call:       callCtl.text.trim().toUpperCase(),
      band:       _freqToBand(freq),
      mode:       modeCtl.text.trim().toUpperCase(),
      freqMhz:    freq,
      timeOn:     q.timeOn,
      timeOff:    q.timeOff,
      rstSent:    rstSCtl.text.trim().isNotEmpty ? rstSCtl.text.trim() : null,
      rstRcvd:    rstRCtl.text.trim().isNotEmpty ? rstRCtl.text.trim() : null,
      name:       nameCtl.text.trim().isNotEmpty ? nameCtl.text.trim() : null,
      gridsquare: q.gridsquare,
      comment:    commentCtl.text.trim().isNotEmpty ? commentCtl.text.trim() : null,
      mySotaRef:  q.mySotaRef,
      sotaRef:    q.sotaRef,
      myPotaRef:  q.myPotaRef,
      potaRef:    q.potaRef,
      extra:      extra,
    );

    final newRecords = List<QsoRecord>.from(_records);
    newRecords[index] = updated;

    // Rewrite file in chronological order (records are stored newest-first).
    final content = AdifLog.encode(newRecords.reversed.toList());
    await File(widget.logPath).writeAsString(content);

    setState(() => _records = newRecords);
  }

  Widget _editField(TextEditingController ctl, String label, {
    TextInputType? keyboard,
    TextCapitalization caps = TextCapitalization.none,
    int maxLines = 1,
  }) {
    return TextField(
      controller: ctl,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      style: const TextStyle(fontSize: 13),
      keyboardType: keyboard,
      textCapitalization: caps,
      maxLines: maxLines,
    );
  }

  String _formatDt(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  static String _freqToBand(double mhz) {
    if (mhz >= 1.8 && mhz < 2.0) return '160m';
    if (mhz >= 3.5 && mhz < 4.0) return '80m';
    if (mhz >= 5.3 && mhz < 5.5) return '60m';
    if (mhz >= 7.0 && mhz < 7.3) return '40m';
    if (mhz >= 10.1 && mhz < 10.15) return '30m';
    if (mhz >= 14.0 && mhz < 14.35) return '20m';
    if (mhz >= 18.068 && mhz < 18.168) return '17m';
    if (mhz >= 21.0 && mhz < 21.45) return '15m';
    if (mhz >= 24.89 && mhz < 24.99) return '12m';
    if (mhz >= 28.0 && mhz < 29.7) return '10m';
    if (mhz >= 50.0 && mhz < 54.0) return '6m';
    if (mhz >= 144.0 && mhz < 148.0) return '2m';
    if (mhz >= 420.0 && mhz < 450.0) return '70cm';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final allBandNames = [
      ...hfBands.map((b) => b.name),
      ...vhfUhfBands.map((b) => b.name),
    ];
    final filtered = _filteredRecords;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
          child: Row(
            children: [
              Text('QSO Log', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(width: 12),
              Text(
                widget.logPath,
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _showAddQsoDialog,
                icon: const Icon(Icons.add),
                label: const Text('New QSO'),
              ),
            ],
          ),
        ),

        // Filter toolbar
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
            children: [
              SizedBox(
                width: 140,
                child: TextField(
                  controller: _searchCtl,
                  decoration: const InputDecoration(
                    hintText: 'Callsign...',
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 18),
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(fontSize: 13),
                  textCapitalization: TextCapitalization.characters,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 100,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Band',
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    border: OutlineInputBorder(),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String?>(
                      value: _bandFilter,
                      isDense: true,
                      isExpanded: true,
                      style: const TextStyle(fontSize: 13),
                      items: [
                        const DropdownMenuItem(
                            value: null, child: Text('All')),
                        ...allBandNames.map((b) => DropdownMenuItem(
                            value: b, child: Text(b))),
                      ],
                      onChanged: (v) => setState(() => _bandFilter = v),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 100,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Mode',
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    border: OutlineInputBorder(),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String?>(
                      value: _modeFilter,
                      isDense: true,
                      isExpanded: true,
                      style: const TextStyle(fontSize: 13),
                      items: _modeOptions
                          .map((m) => DropdownMenuItem<String?>(
                              value: m == 'All' ? null : m,
                              child: Text(m)))
                          .toList(),
                      onChanged: (v) => setState(() => _modeFilter = v),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              if (_hasFilters)
                IconButton(
                  onPressed: _clearFilters,
                  icon: const Icon(Icons.clear, size: 18),
                  tooltip: 'Clear filters',
                  visualDensity: VisualDensity.compact,
                ),
              const SizedBox(width: 8),
              Text(
                _hasFilters
                    ? 'Showing ${filtered.length} of ${_records.length} QSOs'
                    : '${_records.length} QSOs',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _importAdif,
                icon: const Icon(Icons.file_upload, size: 16),
                label: const Text('Import...'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _exportAdif,
                icon: const Icon(Icons.file_download, size: 16),
                label: const Text('Export...'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
              ),
              const SizedBox(width: 8),
              _uploading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : OutlinedButton.icon(
                      onPressed: widget.settings.qrzApiKey.isNotEmpty
                          ? _uploadToQrz
                          : () {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                      'Add your QRZ API key in Preferences'),
                                ),
                              );
                            },
                      icon: const Icon(Icons.cloud_upload, size: 16),
                      label: const Text('Upload to QRZ'),
                      style: OutlinedButton.styleFrom(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 12),
                      ),
                    ),
            ],
          ),
          ),
        ),

        Expanded(
          child: !_loaded
              ? const Center(child: CircularProgressIndicator())
              : _records.isEmpty
                  ? Center(
                      child: Text('No QSOs logged yet.',
                          style: TextStyle(color: Colors.grey.shade500)),
                    )
                  : filtered.isEmpty
                      ? Center(
                          child: Text('No matching QSOs.',
                              style: TextStyle(color: Colors.grey.shade500)),
                        )
                      : LayoutBuilder(
                          builder: (context, constraints) =>
                          SingleChildScrollView(
                          // vertical scroll
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                  minWidth: constraints.maxWidth),
                              child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 24),
                              child: DataTable(
                                headingRowColor: WidgetStatePropertyAll(Colors.grey.shade900),
                                dataRowMinHeight: 28,
                                dataRowMaxHeight: 28,
                                columnSpacing: 16,
                                columns: const [
                                  DataColumn(label: Text('Date/Time')),
                                  DataColumn(label: Text('Callsign')),
                                  DataColumn(label: Text('Freq')),
                                  DataColumn(label: Text('Mode')),
                                  DataColumn(label: Text('RST Sent')),
                                  DataColumn(label: Text('RST Rcvd')),
                                  DataColumn(label: Text('Name')),
                                  DataColumn(label: Text('City')),
                                  DataColumn(label: Text('State')),
                                  DataColumn(label: Text('Country')),
                                  DataColumn(label: Text('Comments')),
                                ],
                                rows: filtered.asMap().entries.map((entry) {
                                  final q = entry.value;
                                  // Map filtered index back to _records index
                                  final recordIdx = _records.indexOf(q);
                                  // Wraps content in a right-click detector.
                                  DataCell cell(Widget child) => DataCell(
                                    GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onSecondaryTapDown: (d) => _showRowMenu(
                                          context, d.globalPosition,
                                          recordIdx, q),
                                      child: SizedBox(
                                        width: double.infinity,
                                        height: double.infinity,
                                        child: Align(
                                          alignment: Alignment.centerLeft,
                                          child: child,
                                        ),
                                      ),
                                    ),
                                  );

                                  return DataRow(
                                    onSelectChanged: (_) =>
                                        _editQso(recordIdx, q),
                                    cells: [
                                    cell(Text(_formatDt(q.timeOn),
                                        style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 12))),
                                    cell(Text(q.call,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold))),
                                    cell(Text(q.freqMhz.toStringAsFixed(3),
                                        style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 12))),
                                    cell(Text(q.mode)),
                                    cell(Text(q.rstSent ?? '',
                                        style: const TextStyle(fontSize: 12))),
                                    cell(Text(q.rstRcvd ?? '',
                                        style: const TextStyle(fontSize: 12))),
                                    cell(Text(q.name ?? '',
                                        style: const TextStyle(fontSize: 12))),
                                    cell(Text(q.extra['QTH'] ?? '',
                                        style: const TextStyle(fontSize: 12))),
                                    cell(Text(q.extra['STATE'] ?? '',
                                        style: const TextStyle(fontSize: 12))),
                                    cell(Text(q.extra['COUNTRY'] ?? '',
                                        style: const TextStyle(fontSize: 12))),
                                    cell(SizedBox(
                                      width: 200,
                                      child: Text(
                                        q.comment ?? '',
                                        style: const TextStyle(
                                            fontSize: 12,
                                            fontStyle: FontStyle.italic),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    )),
                                  ],     // cells
                                  );     // DataRow
                                }).toList(),
                              ),   // DataTable
                            ),     // Padding
                          ),       // ConstrainedBox
                        ),         // horizontal SingleChildScrollView
                      ),           // vertical SingleChildScrollView
                    ),             // LayoutBuilder
        ),                         // Expanded
      ],
    );
  }
}
