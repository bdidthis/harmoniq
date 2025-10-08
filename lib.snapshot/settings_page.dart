import 'package:flutter/material.dart';
import 'key_model.dart';

class AppSettings {
  final int fftSize;
  final int hop;
  final double minHz;
  final double maxHz;
  final double minBpm;
  final double maxBpm;
  final bool hpss;
  final bool useCqt;
  final ModelMode modelMode;
  const AppSettings({
    required this.fftSize,
    required this.hop,
    required this.minHz,
    required this.maxHz,
    required this.minBpm,
    required this.maxBpm,
    required this.hpss,
    required this.useCqt,
    required this.modelMode,
  });
  AppSettings copyWith({
    int? fftSize,
    int? hop,
    double? minHz,
    double? maxHz,
    double? minBpm,
    double? maxBpm,
    bool? hpss,
    bool? useCqt,
    ModelMode? modelMode,
  }) {
    return AppSettings(
      fftSize: fftSize ?? this.fftSize,
      hop: hop ?? this.hop,
      minHz: minHz ?? this.minHz,
      maxHz: maxHz ?? this.maxHz,
      minBpm: minBpm ?? this.minBpm,
      maxBpm: maxBpm ?? this.maxBpm,
      hpss: hpss ?? this.hpss,
      useCqt: useCqt ?? this.useCqt,
      modelMode: modelMode ?? this.modelMode,
    );
  }

  static AppSettings defaults() => const AppSettings(
        fftSize: 4096,
        hop: 1024,
        minHz: 50,
        maxHz: 5000,
        minBpm: 60,
        maxBpm: 200,
        hpss: true,
        useCqt: true,
        modelMode: ModelMode.hybrid,
      );
}

class SettingsPage extends StatefulWidget {
  final AppSettings initial;
  const SettingsPage({super.key, required this.initial});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late int fftSize;
  late int hop;
  late double minHz;
  late double maxHz;
  late double minBpm;
  late double maxBpm;
  late bool hpss;
  late bool useCqt;
  late ModelMode modelMode;

  @override
  void initState() {
    super.initState();
    fftSize = widget.initial.fftSize;
    hop = widget.initial.hop;
    minHz = widget.initial.minHz;
    maxHz = widget.initial.maxHz;
    minBpm = widget.initial.minBpm;
    maxBpm = widget.initial.maxBpm;
    hpss = widget.initial.hpss;
    useCqt = widget.initial.useCqt;
    modelMode = widget.initial.modelMode;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(
                context,
                AppSettings(
                  fftSize: fftSize,
                  hop: hop,
                  minHz: minHz,
                  maxHz: maxHz,
                  minBpm: minBpm,
                  maxBpm: maxBpm,
                  hpss: hpss,
                  useCqt: useCqt,
                  modelMode: modelMode,
                ),
              );
            },
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _numField('FFT Size (power of 2)', fftSize.toString(), (s) {
            final v = int.tryParse(s);
            if (v != null) setState(() => fftSize = v);
          }),
          _numField('Hop', hop.toString(), (s) {
            final v = int.tryParse(s);
            if (v != null) setState(() => hop = v);
          }),
          _numField('Min Hz', minHz.toString(), (s) {
            final v = double.tryParse(s);
            if (v != null) setState(() => minHz = v);
          }),
          _numField('Max Hz', maxHz.toString(), (s) {
            final v = double.tryParse(s);
            if (v != null) setState(() => maxHz = v);
          }),
          _numField('Min BPM', minBpm.toString(), (s) {
            final v = double.tryParse(s);
            if (v != null) setState(() => minBpm = v);
          }),
          _numField('Max BPM', maxBpm.toString(), (s) {
            final v = double.tryParse(s);
            if (v != null) setState(() => maxBpm = v);
          }),
          SwitchListTile(
            title: const Text('HPSS'),
            value: hpss,
            onChanged: (v) => setState(() => hpss = v),
          ),
          SwitchListTile(
            title: const Text('Use CQT Chroma'),
            value: useCqt,
            onChanged: (v) => setState(() => useCqt = v),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Model Mode',
                border: OutlineInputBorder(),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<ModelMode>(
                  value: modelMode,
                  items: const [
                    DropdownMenuItem(
                      value: ModelMode.classical,
                      child: Text('Classical'),
                    ),
                    DropdownMenuItem(
                      value: ModelMode.learned,
                      child: Text('Learned'),
                    ),
                    DropdownMenuItem(
                      value: ModelMode.hybrid,
                      child: Text('Hybrid'),
                    ),
                  ],
                  onChanged: (m) => setState(() => modelMode = m ?? modelMode),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _numField(
    String label,
    String initial,
    ValueChanged<String> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        initialValue: initial,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: onChanged,
      ),
    );
  }
}
