// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:http/http.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart' as shelf;

import 'package:fake_gcloud/mem_datastore.dart';
import 'package:fake_gcloud/mem_storage.dart';
import 'package:fake_pub_server/fake_analyzer_service.dart';
import 'package:fake_pub_server/fake_dartdoc_service.dart';
import 'package:fake_pub_server/fake_pub_server.dart';
import 'package:fake_pub_server/fake_search_service.dart';
import 'package:fake_pub_server/fake_storage_server.dart';
import 'package:pub_dev/frontend/static_files.dart';
import 'package:pub_dev/shared/configuration.dart';

final _argParser = ArgParser()
  ..addOption('port',
      defaultsTo: '8080', help: 'The HTTP port of the fake pub server.')
  ..addOption('storage-port',
      defaultsTo: '8081', help: 'The HTTP port for the fake storage server.')
  ..addOption('search-port',
      defaultsTo: '8082', help: 'The HTTP port for the fake search service.')
  ..addOption('analyzer-port',
      defaultsTo: '8083', help: 'The HTTP port for the fake analyzer service.')
  ..addOption('dartdoc-port',
      defaultsTo: '8084', help: 'The HTTP port for the fake dartdoc service.')
  ..addOption('data-file', help: 'The file to store the local state.');

Future main(List<String> args) async {
  final argv = _argParser.parse(args);
  final port = int.parse(argv['port'] as String);
  final storagePort = int.parse(argv['storage-port'] as String);
  final searchPort = int.parse(argv['search-port'] as String);
  final analyzerPort = int.parse(argv['analyzer-port'] as String);
  final dartdocPort = int.parse(argv['dartdoc-port'] as String);

  Logger.root.onRecord.listen((r) {
    print([
      r.time.toIso8601String(),
      r.toString(),
      r.error,
      r.stackTrace?.toString(),
    ].where((e) => e != null).join(' '));
  });

  final state = _LocalServerState(path: argv['data-file'] as String);
  await state.load();

  final storage = state.storage;
  final datastore = state.datastore;

  final storageServer = FakeStorageServer(storage);
  final pubServer = FakePubServer(datastore, storage);
  final searchService = FakeSearchService(datastore, storage);
  final analyzerService = FakeAnalyzerService(datastore, storage);
  final dartdocService = FakeDartdocService(datastore, storage);

  final configuration = Configuration.fakePubServer(
    frontendPort: port,
    storageBaseUrl: 'http://localhost:$storagePort',
    searchPort: searchPort,
  );

  Future<shelf.Response> _updateUpstream(int port) async {
    final rs = await post('http://localhost:$port/fake-update-all');
    if (rs.statusCode == 200) {
      return shelf.Response.ok('OK');
    } else {
      return shelf.Response(503,
          body: 'Upstream service ($port) returned ${rs.statusCode}.');
    }
  }

  Future<shelf.Response> forwardUpdatesHandler(shelf.Request rq) async {
    if (rq.requestedUri.path == '/fake-update-all') {
      final analyzerRs = await _updateUpstream(analyzerPort);
      if (analyzerRs.statusCode != 200) return analyzerRs;
      final dartdocRs = await _updateUpstream(dartdocPort);
      if (dartdocRs.statusCode != 200) return dartdocRs;
      return await _updateUpstream(searchPort);
    }
    if (rq.requestedUri.path == '/fake-update-analyzer') {
      return await _updateUpstream(analyzerPort);
    }
    if (rq.requestedUri.path == '/fake-update-dartdoc') {
      return await _updateUpstream(dartdocPort);
    }
    if (rq.requestedUri.path == '/fake-update-search') {
      return await _updateUpstream(searchPort);
    }
    return null;
  }

  // Store the state (and then exit) on CTRL+C.
  final sigintSubscription = ProcessSignal.sigint.watch().listen((e) async {
    await state.save();
    exit(0);
  });

  await updateLocalBuiltFilesIfNeeded();
  await Future.wait(
    [
      storageServer.run(port: storagePort),
      pubServer.run(
        port: port,
        configuration: configuration,
        extraHandler: forwardUpdatesHandler,
      ),
      searchService.run(
        port: searchPort,
        configuration: configuration,
      ),
      analyzerService.run(
        port: analyzerPort,
        configuration: configuration,
      ),
      dartdocService.run(
        port: dartdocPort,
        configuration: configuration,
      ),
    ],
    eagerError: true,
  );

  await state.save();
  await sigintSubscription.cancel();
}

/// Owns server state, optionally loading / saving state to/from the specified file.
class _LocalServerState {
  final datastore = MemDatastore();
  final storage = MemStorage();
  File _file;
  Completer _storingCompleter;

  _LocalServerState({String path}) {
    if (path != null) {
      _file = File(path);
    }
  }

  Future<void> load() async {
    if (_file != null && await _file.exists()) {
      final lines =
          _file.openRead().transform(utf8.decoder).transform(LineSplitter());
      var marker = 'start';
      await for (final line in lines) {
        if (line.startsWith('{"marker":')) {
          final map = json.decode(line) as Map<String, dynamic>;
          marker = map['marker'] as String;
          continue;
        }
        switch (marker) {
          case 'datastore':
            datastore.readFrom([line]);
            continue;
          case 'storage':
            storage.readFrom([line]);
            continue;
        }
        throw ArgumentError('Marker not state failed: $marker - $line');
      }
    }
  }

  Future<void> save() async {
    while (_storingCompleter != null) {
      await _storingCompleter.future;
    }
    _storingCompleter = Completer();
    try {
      print('Storing state in ${_file.path}...');
      if (_file != null) {
        await _file.parent.create(recursive: true);
      }
      final sink = _file.openWrite();

      void writeMarker(String marker) {
        sink.writeln(json.encode({'marker': marker}));
      }

      writeMarker('datastore');
      datastore.writeTo(sink);

      writeMarker('storage');
      storage.writeTo(sink);

      writeMarker('end');
      await sink.close();
    } finally {
      _storingCompleter.complete();
      _storingCompleter = null;
    }
  }
}
