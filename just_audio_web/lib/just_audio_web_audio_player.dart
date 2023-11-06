import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:just_audio_web/just_audio_web.dart';
import 'package:soundpool/soundpool.dart';

class JustAudioPlugin extends JustAudioPlatform {
  final Map<String, FithubAudioPlayer> players = {};

  /// The entrypoint called by the generated plugin registrant.
  static void registerWith(Registrar registrar) {
    JustAudioPlatform.instance = JustAudioPlugin();
  }

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    if (players.containsKey(request.id)) {
      throw PlatformException(
          code: "error",
          message: "Platform player ${request.id} already exists");
    }
    print("defaultTargetPlatform $defaultTargetPlatform : kIsWeb $kIsWeb");
    // final player = defaultTargetPlatform == TargetPlatform.iOS && kIsWeb
    //     ? WebAudioAPIPlayer(id: request.id)
    //     : Html5AudioPlayer(id: request.id);
    final player = WebAudioAPIPlayer(id: request.id);
    players[request.id] = player;
    return player;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
      DisposePlayerRequest request) async {
    await players[request.id]?.release();
    players.remove(request.id);
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
      DisposeAllPlayersRequest request) async {
    for (var player in players.values) {
      await player.release();
    }
    players.clear();
    for (var element in players.values) {
      element.dispose(DisposeRequest());
    }
    return DisposeAllPlayersResponse();
  }
}

abstract class JustAudioPlayer extends FithubAudioPlayer {
  final _eventController = StreamController<PlaybackEventMessage>.broadcast();
  final _dataEventController = StreamController<PlayerDataMessage>.broadcast();
  ProcessingStateMessage _processingState = ProcessingStateMessage.idle;
  bool _playing = false;
  int? _index;
  double _speed = 1.0;

  LoopModeMessage _loopMode = LoopModeMessage.off;

  /// Creates a platform player with the given [id].
  JustAudioPlayer({required String id}) : super(id);

  @mustCallSuper
  Future<void> release() async {
    _eventController.close();
    _dataEventController.close();
  }

  /// Returns the current position of the player.
  Duration getCurrentPosition();

  /// Returns the current buffered position of the player.
  Duration getBufferedPosition();

  /// Returns the duration of the current player item or `null` if unknown.
  Duration? getDuration();

  /// Broadcasts a playback event from the platform side to the plugin side.
  void broadcastPlaybackEvent() {
    var updateTime = DateTime.now();
    _eventController.add(PlaybackEventMessage(
      processingState: _processingState,
      updatePosition: getCurrentPosition(),
      updateTime: updateTime,
      bufferedPosition: getBufferedPosition(),
      // TODO: Icy Metadata
      icyMetadata: null,
      duration: getDuration(),
      currentIndex: _index,
      androidAudioSessionId: null,
    ));
  }

  /// Transitions to [processingState] and broadcasts a playback event.
  void transition(ProcessingStateMessage processingState) {
    _processingState = processingState;
    broadcastPlaybackEvent();
  }
}

class WebAudioAPIPlayer extends JustAudioPlayer {
  WebAudioAPIPlayer({required String id}) : super(id: id);

  final _eventController = StreamController<PlaybackEventMessage>.broadcast();
  final _dataEventController = StreamController<PlayerDataMessage>.broadcast();

  final Soundpool soundpool = Soundpool.fromOptions(
      options: const SoundpoolOptions(
    webOptions: SoundpoolOptionsWeb(),
  ));
  final Map<String, Future<int>> _audioSourcesIds = {};

  final Map<String, AudioSourcePlayer> _audioSourcePlayers = {};

  AudioSourcePlayer? _audioSourcePlayer;
  bool _shuffleModeEnabled = false;

  /// The current playback order, depending on whether shuffle mode is enabled.
  List<int> get order {
    final sequence = _audioSourcePlayer!.sequence;
    return _shuffleModeEnabled
        ? _audioSourcePlayer!.shuffleIndices
        : List.generate(sequence.length, (i) => i);
  }

  /// gets the inverted order for the given order.
  List<int> getInv(List<int> order) {
    final orderInv = List<int>.filled(order.length, 0);
    for (var i = 0; i < order.length; i++) {
      orderInv[order[i]] = i;
    }
    return orderInv;
  }

  /// Called when playback reaches the end of an item.
  Future<void> onEnded() async {
    if (_loopMode == LoopModeMessage.one) {
      await _seek(0, null);
      _play();
    } else {
      final order = this.order;
      final orderInv = getInv(order);
      if (orderInv[_index!] + 1 < order.length) {
        // move to next item
        _index = order[orderInv[_index!] + 1];
        await _currentAudioSourcePlayer!.load();
        // Should always be true...
        if (_playing) {
          _play();
        }
      } else {
        // reached end of playlist
        if (_loopMode == LoopModeMessage.all) {
          // Loop back to the beginning
          if (order.length == 1) {
            await _seek(0, null);
            _play();
          } else {
            _index = order[0];
            await _currentAudioSourcePlayer!.load();
            // Should always be true...
            if (_playing) {
              _play();
            }
          }
        } else {
          await _currentAudioSourcePlayer?.pause();
          transition(ProcessingStateMessage.completed);
        }
      }
    }
  }

  // TODO: Improve efficiency.
  IndexedAudioSourcePlayer? get _currentAudioSourcePlayer {
    return _audioSourcePlayer != null &&
            _index != null &&
            _audioSourcePlayer!.sequence.isNotEmpty &&
            _index! < _audioSourcePlayer!.sequence.length
        ? _audioSourcePlayer!.sequence[_index!]
        : null;
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _eventController.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream =>
      _dataEventController.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _index = request.initialIndex ?? 0;
    await _currentAudioSourcePlayer?.pause();
    _audioSourcePlayer = await getAudioSource(request.audioSourceMessage);
    final duration = await _currentAudioSourcePlayer!
        .load(request.initialPosition?.inMilliseconds);
    if (request.initialPosition != null) {
      _currentAudioSourcePlayer!.positionOffset =
          request.initialPosition!.inMilliseconds / 1000;
    }
    transition(ProcessingStateMessage.ready);

    if (_playing) {
      await _currentAudioSourcePlayer!.play();
    }
    return LoadResponse(duration: duration);
  }

  /// Loads audio from [uri] and returns the duration of the loaded audio if
  /// known.
  Future<Duration?> loadUri(
      final Uri uri, final Duration? initialPosition) async {
    transition(ProcessingStateMessage.loading);
    Future<Duration?> getDuration() async {
      return Duration(
          milliseconds: ((await soundpool
                      .getDuration(await _audioSourcesIds[uri.toString()]!)) *
                  1000)
              .toInt());
    }

    if (_audioSourcesIds.containsKey(uri.toString())) {
      return getDuration();
    }
    final id = soundpool.loadUri(uri.toString());
    _audioSourcesIds[uri.toString()] = id;
    await id;
    transition(ProcessingStateMessage.ready);
    return getDuration();
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    if (_playing) return PlayResponse();
    _playing = true;
    await _play();
    return PlayResponse();
  }

  Future<void> _play() async {
    await _currentAudioSourcePlayer?.play();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    if (!_playing) return PauseResponse();
    _playing = false;
    _currentAudioSourcePlayer?.pause();
    return PauseResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    final source = _currentAudioSourcePlayer;
    Future<void> applyVolume(IndexedAudioSourcePlayer player) async {
      if (player.sequence.length > 1) {
        await Future.wait(player.sequence.map((e) => applyVolume(e)));
      } else {
        await soundpool.setVolume(
            soundId: player.soundId,
            streamId: player.streamId,
            volume: request.volume);
      }
    }

    if (source != null) {
      applyVolume(source);
    }
    return SetVolumeResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    final source = _currentAudioSourcePlayer;
    if (source != null) {
      await soundpool.setRate(
          streamId: source.streamId, playbackRate: request.speed);
    }
    return SetSpeedResponse();
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    _loopMode = request.loopMode;
    return SetLoopModeResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
      SetShuffleModeRequest request) async {
    _shuffleModeEnabled = request.shuffleMode == ShuffleModeMessage.all;
    return SetShuffleModeResponse();
  }

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
      SetShuffleOrderRequest request) async {
    void internalSetShuffleOrder(AudioSourceMessage sourceMessage) {
      final audioSourcePlayer = _audioSourcePlayers[sourceMessage.id];
      if (audioSourcePlayer == null) return;
      if (sourceMessage is ConcatenatingAudioSourceMessage &&
          audioSourcePlayer is ConcatenatingAudioSourcePlayer) {
        audioSourcePlayer.setShuffleOrder(sourceMessage.shuffleOrder);
        for (var childMessage in sourceMessage.children) {
          internalSetShuffleOrder(childMessage);
        }
      } else if (sourceMessage is LoopingAudioSourceMessage) {
        internalSetShuffleOrder(sourceMessage.child);
      }
    }

    internalSetShuffleOrder(request.audioSourceMessage);
    return SetShuffleOrderResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    await _seek(request.position?.inMilliseconds ?? 0, request.index);
    return SeekResponse();
  }

  Future<void> _seek(int position, int? newIndex) async {
    var index = newIndex ?? _index;
    if (index != _index) {
      _currentAudioSourcePlayer!.pause();
      _index = index;
      await _currentAudioSourcePlayer!.load(position);
      if (_playing) {
        _currentAudioSourcePlayer!.play();
      }
    } else {
      await _currentAudioSourcePlayer!.seek(position);
    }
  }

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
      ConcatenatingInsertAllRequest request) async {
    final wasNotEmpty = _audioSourcePlayer?.sequence.isNotEmpty ?? false;
    _concatenating(request.id)!.setShuffleOrder(request.shuffleOrder);
    _concatenating(request.id)!
        .insertAll(request.index, await getAudioSources(request.children));
    if (_index != null && wasNotEmpty && request.index <= _index!) {
      _index = _index! + request.children.length;
    }
    await _currentAudioSourcePlayer!.load();
    broadcastPlaybackEvent();
    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
      ConcatenatingRemoveRangeRequest request) async {
    if (_index != null &&
        _index! >= request.startIndex &&
        _index! < request.endIndex &&
        _playing) {
      // Pause if removing current item
      _currentAudioSourcePlayer!.pause();
    }
    _concatenating(request.id)!.setShuffleOrder(request.shuffleOrder);
    _concatenating(request.id)!
        .removeRange(request.startIndex, request.endIndex);
    if (_index != null) {
      if (_index! >= request.startIndex && _index! < request.endIndex) {
        // Skip backward if there's nothing after this
        if (request.startIndex >= _audioSourcePlayer!.sequence.length) {
          _index = request.startIndex - 1;
          if (_index! < 0) _index = 0;
        } else {
          _index = request.startIndex;
        }
        // Resume playback at the new item (if it exists)
        if (_currentAudioSourcePlayer != null) {
          await _currentAudioSourcePlayer!.load();
          if (_playing) {
            _currentAudioSourcePlayer!.play();
          }
        }
      } else if (request.endIndex <= _index!) {
        // Reflect that the current item has shifted its position
        _index = _index! - (request.endIndex - request.startIndex);
      }
    }
    broadcastPlaybackEvent();
    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(
      ConcatenatingMoveRequest request) async {
    _concatenating(request.id)!.setShuffleOrder(request.shuffleOrder);
    _concatenating(request.id)!.move(request.currentIndex, request.newIndex);
    if (_index != null) {
      if (request.currentIndex == _index) {
        _index = request.newIndex;
      } else if (request.currentIndex < _index! &&
          request.newIndex >= _index!) {
        _index = _index! - 1;
      } else if (request.currentIndex > _index! &&
          request.newIndex <= _index!) {
        _index = _index! + 1;
      }
    }
    broadcastPlaybackEvent();
    return ConcatenatingMoveResponse();
  }

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
      SetAndroidAudioAttributesRequest request) async {
    return SetAndroidAudioAttributesResponse();
  }

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
      setAutomaticallyWaitsToMinimizeStalling(
          SetAutomaticallyWaitsToMinimizeStallingRequest request) async {
    return SetAutomaticallyWaitsToMinimizeStallingResponse();
  }

  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
      setCanUseNetworkResourcesForLiveStreamingWhilePaused(
          SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest
              request) async {
    return SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();
  }

  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(
      SetPreferredPeakBitRateRequest request) async {
    return SetPreferredPeakBitRateResponse();
  }

  @override
  Duration getCurrentPosition() =>
      _currentAudioSourcePlayer?.position ?? Duration.zero;

  @override
  Duration getBufferedPosition() =>
      _currentAudioSourcePlayer?.bufferedPosition ?? Duration.zero;

  @override
  Duration? getDuration() => _currentAudioSourcePlayer?.duration;

  @override
  Future<void> release() async {
    _currentAudioSourcePlayer?.pause();
    transition(ProcessingStateMessage.idle);
    _currentAudioSourcePlayer?.dispose();
    soundpool.release();
    return await super.release();
  }

  ConcatenatingAudioSourcePlayer? _concatenating(String playerId) =>
      _audioSourcePlayers[playerId] as ConcatenatingAudioSourcePlayer?;

  /// Converts a list of audio source messages to players.
  Future<List<AudioSourcePlayer>> getAudioSources(
          List<AudioSourceMessage> messages) async =>
      (await Future.wait(messages.map((message) => getAudioSource(message))))
          .toList();

  /// Converts an audio source message to a player, using the cache if it is
  /// already cached.
  Future<AudioSourcePlayer> getAudioSource(
      AudioSourceMessage audioSourceMessage) async {
    final id = audioSourceMessage.id;
    var audioSourcePlayer = _audioSourcePlayers[id];
    if (audioSourcePlayer == null) {
      audioSourcePlayer = await decodeAudioSource(audioSourceMessage);
      _audioSourcePlayers[id] = audioSourcePlayer;
    }
    return audioSourcePlayer;
  }

  /// Converts an audio source message to a player.
  Future<AudioSourcePlayer> decodeAudioSource(
      AudioSourceMessage audioSourceMessage) async {
    Future<int> getSourceId(String uri) async {
      final Future<int> soundId = _audioSourcesIds[uri] ?? soundpool.loadUri(uri);
      _audioSourcesIds[uri] = soundId;
      print("decode audio source: ${await soundId} $uri");
      return await soundId;
    }

    Future<int> getStreamId(int soundId) async {
      final streamId = await soundpool.play(soundId);
      await soundpool.pause(streamId);
      return streamId;
    }

    if (audioSourceMessage is ProgressiveAudioSourceMessage) {
      final soundId = await getSourceId(audioSourceMessage.uri);
      final streamId = await getStreamId(soundId);
      return ProgressiveAudioSourcePlayer(
          Uri.parse(audioSourceMessage.uri), audioSourceMessage.headers,
          audioPlayer: this, soundId: soundId, streamId: streamId);
    } else if (audioSourceMessage is DashAudioSourceMessage) {
      final soundId = await getSourceId(audioSourceMessage.uri);
      final streamId = await getStreamId(soundId);
      return DashAudioSourcePlayer(
          Uri.parse(audioSourceMessage.uri), audioSourceMessage.headers,
          audioPlayer: this, streamId: streamId, soundId: soundId);
    } else if (audioSourceMessage is HlsAudioSourceMessage) {
      final soundId = await getSourceId(audioSourceMessage.uri);
      final streamId = await getStreamId(soundId);
      return HlsAudioSourcePlayer(
          Uri.parse(audioSourceMessage.uri), audioSourceMessage.headers,
          audioPlayer: this, streamId: streamId, soundId: soundId);
    } else if (audioSourceMessage is ConcatenatingAudioSourceMessage) {
      return ConcatenatingAudioSourcePlayer(
          await getAudioSources(audioSourceMessage.children),
          audioSourceMessage.useLazyPreparation,
          streamId: 0,
          audioPlayer: this,
          soundId: 0,
          shuffleOrder: audioSourceMessage.shuffleOrder);
    } else {
      throw Exception("Unknown AudioSource type: $audioSourceMessage");
    }
  }
}

/// A player for a [ProgressiveAudioSourceMessage].
class ProgressiveAudioSourcePlayer extends UriAudioSourcePlayer {
  ProgressiveAudioSourcePlayer(Uri uri, Map<String, String>? headers,
      {required WebAudioAPIPlayer audioPlayer,
      required int streamId,
      required int soundId})
      : super(uri, headers,
            audioPlayer: audioPlayer, streamId: streamId, soundId: soundId);

  @override
  void dispose() {}
}

/// A player for a [DashAudioSourceMessage].
class DashAudioSourcePlayer extends UriAudioSourcePlayer {
  DashAudioSourcePlayer(Uri uri, Map<String, String>? headers,
      {required WebAudioAPIPlayer audioPlayer,
      required int streamId,
      required int soundId})
      : super(uri, headers,
            audioPlayer: audioPlayer, streamId: streamId, soundId: soundId);

  @override
  void dispose() {}
}

/// A player for a [HlsAudioSourceMessage].
class HlsAudioSourcePlayer extends UriAudioSourcePlayer {
  HlsAudioSourcePlayer(Uri uri, Map<String, String>? headers,
      {required WebAudioAPIPlayer audioPlayer,
      required int streamId,
      required int soundId})
      : super(uri, headers,
            audioPlayer: audioPlayer, streamId: streamId, soundId: soundId);

  @override
  void dispose() {}
}

abstract class AudioSourcePlayer {
  /// The [WebAudioAPIPlayer] responsible for audio I/O.
  WebAudioAPIPlayer audioPlayer;

  /// The ID of the underlying audio source.
  int soundId;
  int streamId;
  double positionOffset;

  List<IndexedAudioSourcePlayer> get sequence;

  List<int> get shuffleIndices;

  AudioSourcePlayer(
      {required this.audioPlayer,
      required this.streamId,
      required this.soundId,
      this.positionOffset = 0});

  void dispose();
}

abstract class IndexedAudioSourcePlayer extends AudioSourcePlayer {
  IndexedAudioSourcePlayer(
      {required WebAudioAPIPlayer audioPlayer,
      required int streamId,
      required int soundId})
      : super(audioPlayer: audioPlayer, streamId: streamId, soundId: soundId);

  /// Loads the audio for the underlying audio source.
  Future<Duration?> load([int? initialPosition]);

  /// Plays the underlying audio source.
  Future<void> play();

  /// Pauses playback of the underlying audio source.
  Future<void> pause();

  /// Seeks to [position] milliseconds.
  Future<void> seek(int position);

  /// Called when playback reaches the end of the underlying audio source.
  Future<void> complete();

  /// Called when the playback position of the underlying HTML5 player changes.
  Future<void> timeUpdated(double seconds) async {}

  /// The duration of the underlying audio source.
  Duration? get duration;

  /// The current playback position.
  Duration get position;

  /// The current buffered position.
  Duration get bufferedPosition;

  @override
  String toString() => "$runtimeType";

  @override
  void dispose();
}

class ConcatenatingAudioSourcePlayer extends AudioSourcePlayer {
  /// The players for each child audio source.
  final List<AudioSourcePlayer> audioSourcePlayers;

  /// Whether audio should be loaded as late as possible. (Currently ignored.)
  final bool useLazyPreparation;
  List<int> _shuffleOrder;

  ConcatenatingAudioSourcePlayer(
      this.audioSourcePlayers, this.useLazyPreparation,
      {required WebAudioAPIPlayer audioPlayer,
      required int streamId,
      required int soundId,
      required List<int> shuffleOrder})
      : _shuffleOrder = shuffleOrder,
        super(audioPlayer: audioPlayer, streamId: streamId, soundId: soundId);

  @override
  List<IndexedAudioSourcePlayer> get sequence =>
      audioSourcePlayers.expand((p) => p.sequence).toList();

  @override
  List<int> get shuffleIndices {
    final order = <int>[];
    var offset = order.length;
    final childOrders = <List<int>>[];
    for (var audioSourcePlayer in audioSourcePlayers) {
      final childShuffleIndices = audioSourcePlayer.shuffleIndices;
      childOrders.add(childShuffleIndices.map((i) => i + offset).toList());
      offset += childShuffleIndices.length;
    }
    for (var i = 0; i < childOrders.length; i++) {
      order.addAll(childOrders[_shuffleOrder[i]]);
    }
    return order;
  }

  /// Sets the current shuffle order.
  void setShuffleOrder(List<int> shuffleOrder) {
    _shuffleOrder = shuffleOrder;
  }

  /// Inserts [players] into this player at position [index].
  void insertAll(int index, List<AudioSourcePlayer> players) {
    audioSourcePlayers.insertAll(index, players);
    for (var i = 0; i < audioSourcePlayers.length; i++) {
      if (_shuffleOrder[i] >= index) {
        _shuffleOrder[i] += players.length;
      }
    }
  }

  /// Removes the child players in the specified range.
  void removeRange(int start, int end) {
    audioSourcePlayers.removeRange(start, end);
    for (var i = 0; i < audioSourcePlayers.length; i++) {
      if (_shuffleOrder[i] >= end) {
        _shuffleOrder[i] -= (end - start);
      }
    }
  }

  /// Moves a child player from [currentIndex] to [newIndex].
  void move(int currentIndex, int newIndex) {
    audioSourcePlayers.insert(
        newIndex, audioSourcePlayers.removeAt(currentIndex));
  }

  @override
  void dispose() {
    for (var element in audioSourcePlayers) {
      element.dispose();
    }
  }
}

abstract class UriAudioSourcePlayer extends IndexedAudioSourcePlayer {
  /// The URL to play.
  final Uri uri;

  /// The headers to include in the request (unsupported).
  final Map<String, String>? headers;
  double? _resumePos;
  Duration? _duration;
  Completer<dynamic>? _completer;
  int? _initialPos;

  Timer? _updateTimer;
  Duration _lastPosition = Duration.zero;

  UriAudioSourcePlayer(this.uri, this.headers,
      {required WebAudioAPIPlayer audioPlayer,
      required int streamId,
      required int soundId})
      : super(audioPlayer: audioPlayer, streamId: streamId, soundId: soundId);

  @override
  List<IndexedAudioSourcePlayer> get sequence => [this];

  @override
  List<int> get shuffleIndices => [0];

  @override
  Future<Duration?> load([int? initialPosition]) async {
    _initialPos = initialPosition;
    _resumePos = (initialPosition ?? 0) / 1000.0;

    _duration = await audioPlayer.loadUri(
        uri,
        initialPosition != null
            ? Duration(milliseconds: initialPosition)
            : null);
    _initialPos = null;
    return _duration;
  }

  void _setUpdateTime() {
    _updateTimer ??=
        Timer.periodic(const Duration(milliseconds: 500), (timer) async {
      _lastPosition = Duration(
          milliseconds:
              ((await audioPlayer.soundpool.getPosition(streamId)) * 1000)
                  .toInt());
      final available =
          await audioPlayer.soundpool.checkAvailability(streamId);
      if (!available) {
        timer.cancel();
        await complete();
      }
    });
  }

  @override
  Future<void> play() async {
    await audioPlayer.soundpool.resume(streamId);
    _setUpdateTime();
    _completer = Completer<dynamic>();
    await _completer!.future;
    _completer = null;
  }

  @override
  Future<void> pause() async {
    _updateTimer?.cancel();
    await audioPlayer.soundpool.pause(streamId);
    _interruptPlay();
  }

  @override
  Future<void> seek(int position) async {
    await audioPlayer.soundpool.seek(streamId, position / 1000);
  }

  @override
  Future<void> complete() async {
    _interruptPlay();
    audioPlayer.onEnded();
  }

  void _interruptPlay() {
    if (_completer?.isCompleted == false) {
      _completer!.complete();
    }
  }

  @override
  Duration? get duration {
    return _duration;
    //final seconds = _audioElement.duration;
    //return seconds.isFinite
    //    ? Duration(milliseconds: (seconds * 1000).toInt())
    //    : null;
  }

  @override
  Duration get position {
    return _lastPosition;
  }

  @override
  Duration get bufferedPosition {
    return Duration.zero;
  }

  @override
  void dispose() {
    audioPlayer.soundpool.dispose();
    _updateTimer?.cancel();
  }
}
