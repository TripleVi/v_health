import 'dart:async';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_activity_recognition/flutter_activity_recognition.dart' as far;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get_it/get_it.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/enum/activity_category.dart';
import '../../../core/enum/activity_tracking.dart';
import '../../../core/services/classification_service.dart';
import '../../../core/services/location_service.dart';
import '../../../core/services/sensor_service.dart';
import '../../../core/services/user_service.dart';
import '../../../domain/entities/activity_record.dart';
import '../../../domain/entities/workout_data.dart';
import '../../../main.dart';
import '../widgets/marker_painter.dart';
import 'activity_tracking.dart';
import 'cycling_activity.dart';
import 'running_activity.dart';
import 'walking_activity.dart';

part 'activity_tracking_event.dart';
part 'activity_tracking_state.dart';

class LocationSettingsRequest {
  final String title;
  final String description;
  final Future<void> Function() openSettings;

  LocationSettingsRequest({
    required this.title, 
    required this.description, 
    required this.openSettings,
  });

  factory LocationSettingsRequest.permissionGranted() {
    return LocationSettingsRequest(
      title: "Location Services",
      description: "You must open App Settings and grant Location Permission to record an activity",
      openSettings: LocationService.openAppSettings,
    );
  }

  factory LocationSettingsRequest.serviceEnabled() {
    return LocationSettingsRequest(
      title: "Location Services",
      description: "You must open Settings and enable Location Services to record an activity",
      openSettings: LocationService.openLocationSettings,
    );
  }

  factory LocationSettingsRequest.accuracyPrecise() {
    return LocationSettingsRequest(
      title: "Location Services",
      description: "You must open Settings and allow the app to use Precise Location to record an activity",
      openSettings: LocationService.openLocationSettings,
    );
  }

  factory LocationSettingsRequest.permissionAlways() {
    return LocationSettingsRequest(
      title: "Location Services",
      description: "You must open Settings and allow Location Permission as Always to record an activity in background",
      openSettings: LocationService.openLocationSettings,
    );
  }
}

class PhotoParams {
  XFile file;
  double latitude;
  double longitude;

  PhotoParams({
    required this.file,
    required this.latitude,
    required this.longitude,
  });

  @override
  String toString() {
    return "PhotoTaken{path: ${file.path}, latitude: $latitude, longitude: $longitude}";
  }
}

class TrackingResult {
  final List<LatLng> geoPoints;
  final List<PhotoParams> photosParams;
  final ActivityRecord record;
  final Completer<GoogleMapController> controller;
  final LatLngBounds latLngBounds;

  TrackingResult({
    required this.geoPoints, 
    required this.photosParams,
    required this.record,
    required this.controller,
    required this.latLngBounds,
  });
}

class ActivityTrackingBloc extends Bloc<ActivityTrackingEvent, TrackingState> with WidgetsBindingObserver {
  final _geoPoints = <LatLng>[];
  final _markers = <Marker>{};
  final _photosParams = <PhotoParams>[];
  Position? _curtPos;
  Position? _lastKnownPos;
  StreamSubscription<Position>? _positionSubscriber;
  StreamSubscription<far.Activity>? _activitySubscriber;
  ActivityTracking? activity;

  final _locationService = GetIt.instance<LocationService>();
  final _timeStreamController = StreamController<int>.broadcast();
  late Timer _timer;
  int _secondsElapsed = 0;

  var _topMost = -double.maxFinite;
  var _rightMost = -double.maxFinite;
  var _leftMost = double.maxFinite;
  var _bottomMost = double.maxFinite;

  final _mapController = Completer<GoogleMapController>();
  bool _isProcessing = true;
  var _locSvcEnabled = false;
  var _locPermission = LocationPermission.denied;
  var _locAccuracyStatus = LocationAccuracyStatus.reduced;
  

  var rawActiveData = <List<double>>[];
  Timer? activeTimer;

  ActivityTrackingBloc() : super(const TrackingState()) {
    on<TrackingStarted>(_onTrackingStarted);
    on<TrackingPaused>(_onTrackingPaused);
    on<TrackingResumed>(_onTrackingResumed);
    on<TrackingFinished>(_onTrackingFinished);
    on<TrackingSaved>(_onTrackingSaved);
    on<DropDownItemSelected>(_onDropDownItemSelected);
    on<PictureTaken>(_onPictureTaken);
    on<PhotoMarkerTapped>(_onPhotoMarkerTapped);
    on<PhotoDeleted>(_onPhotoDeleted);
    on<PhotoEdited>(_onPhotoEdited);
    on<RefreshTracking>(_onRefreshTracking);
    on<LocationUpdated>(_onLocationUpdated);
    on<CategorySelected>(_onCategorySelected);

    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      requestLocationPermission().then((_) async {
        if(_locAccuracyStatus == LocationAccuracyStatus.precise) {
          await _onDesiredLocation();
        }
        _isProcessing = false;
      });
    });
  }

  Future<void> requestLocationPermission() async {
    _locSvcEnabled = await Geolocator.isLocationServiceEnabled();
    _locPermission = await Geolocator.checkPermission();
    // _locPermission cannot be deniedForever at this time.
    // No options are selected or it's been denied permanently before.
    if(_locPermission == LocationPermission.denied) {
      // If the permission is denied forever, the dialog won't be shown again.
      _locPermission = await Geolocator.requestPermission();
      try {
        // To check whether options are selected.
        _locAccuracyStatus = await Geolocator.getLocationAccuracy();
        // It's been disallowed or selected and couldn't be denied.
      } on PlatformException catch (e) {
        // No options are selected. '_locPermission' is denied or deniedForever.
        if(e.code != "PERMISSION_DENIED") rethrow;
        // 'denied': the accuracy selected in the previous use is precise.
        // 'deniedForever': it's approximate, likewise.
        if(_locPermission == LocationPermission.deniedForever) {
          // 'denied' is possible to request for the next time.
          // 'deniedForever' is impossible to request and needs to open app settings.
          _locPermission = LocationPermission.denied;
        }
      }
      return;
    }
    // The permission's been allowed before with approximate or precise accuracy.
    // If it's approximate, an accuracy dialog of precise will be shown.
    // If it's approximate permanently, nothing will happen.
    // It's impossible to know whether the selection is permanent.
    _locAccuracyStatus = await Geolocator.getLocationAccuracy();
    if(_locAccuracyStatus == LocationAccuracyStatus.precise) return;
    final result = await Permission.location.request();
    // 'denied': the previous accuracy is precise and no options are selected.
    // 'permanentlyDenied': the previous accuracy is approximate and no options are selected; the selected one is approximate permanently.
    // 'granted': the selected accuracy is precise.
    if(result.isGranted) {
      _locAccuracyStatus = LocationAccuracyStatus.precise;
    }
  }

  Future<void> handleLocationPermission(Emitter<TrackingState> emit) async {
    // This is called when users touch 'Start' or 'Resume' button.
    if(!_locSvcEnabled) {
      return emit(state.copyWith(
        request : LocationSettingsRequest.serviceEnabled(),
      ));
    }
    if(_locPermission == LocationPermission.deniedForever) {
      return emit(state.copyWith(
        request : LocationSettingsRequest.permissionGranted(),
      ));
    }
    // No options were selected in the previous request.
    if(_locPermission == LocationPermission.denied) {
      // If it's denied forever, the dialog won't be shown again.
      _locPermission = await Geolocator.requestPermission();
      try {
        // To check whether options are selected.
        _locAccuracyStatus = await Geolocator.getLocationAccuracy();
        // It's been disallowed or selected and couldn't be denied.
      } on PlatformException catch (e) {
        // No options are selected.
        if(e.code != "PERMISSION_DENIED") rethrow;
        // 'denied': the selected accuracy is precise.
        // 'deniedForever': the selected accuracy is approximate.
        if(_locPermission == LocationPermission.deniedForever) {
          _locPermission = LocationPermission.denied;
        }
      }
      return;
    }
    _locAccuracyStatus = await Geolocator.getLocationAccuracy();
    if(_locAccuracyStatus == LocationAccuracyStatus.precise) return;
    final result = await Permission.location.request();
    if(result.isDenied) {
      _locAccuracyStatus = LocationAccuracyStatus.reduced;
    }else if(result.isPermanentlyDenied) {
      emit(state.copyWith(
        request: LocationSettingsRequest.accuracyPrecise(),
      ));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed: 
        _onAppStateResumed();
        break;
      case AppLifecycleState.paused:
        backgroundService.invoke("appStateUpdated", {
          "state": "paused"
        });
        break;
      default:
        break;
    }
  }

  Future<void> _onAppStateResumed() async {
    var flag = false;
    backgroundService.invoke("appStateUpdated", {
      "state": "resumed"
    });
    _locSvcEnabled = await Geolocator.isLocationServiceEnabled();
    final permission = await Geolocator.checkPermission();
    try {
      // To check whether options are selected.
      _locAccuracyStatus = await Geolocator.getLocationAccuracy();
      // It's been disallowed or selected and couldn't be denied.
      _locPermission = permission;
    } on PlatformException catch (e) {
      // No options are selected.
      if(e.code != "PERMISSION_DENIED") rethrow;
      if(permission == LocationPermission.deniedForever) {
        _locPermission = LocationPermission.denied;
      }
    }
    flag = !_locSvcEnabled || _locPermission == LocationPermission.denied || _locPermission == LocationPermission.deniedForever || _locAccuracyStatus == LocationAccuracyStatus.reduced;
    if(flag) {
      _curtPos = null;
      activity!.pauseTracking();
      add(const RefreshTracking());
    }
  }

  Future<void> requestPermissions() async {
    final activityRecognition = far.FlutterActivityRecognition.instance;
    var reqResult = await activityRecognition.checkPermission();
    if(reqResult == far.PermissionRequestResult.PERMANENTLY_DENIED) {
      return;
    }else if (reqResult == far.PermissionRequestResult.DENIED) {
      reqResult = await activityRecognition.requestPermission();
      if (reqResult != far.PermissionRequestResult.GRANTED) {
        return;
      }
    }
    _activitySubscriber = activityRecognition.activityStream
        .listen((event) {
          print(event.toString());
          if(state.status.isStarted && state.category.isCycling && event.type != far.ActivityType.ON_BICYCLE && event.confidence == far.ActivityConfidence.HIGH) {
            // emit(state)
          }
        });
  }

  Future<void> _onDesiredLocation() async {
    //? Accuracy status is precise and first time or location update's interrupted (currentPosition == null).
    //? currentPosition will be equal to 'null' only if it hasn't been initialized yet or tracking encounters errors.
    _curtPos = await _locationService.getCurrentPosition();
    _lastKnownPos = _curtPos!;
    final controller = await _mapController.future;
    controller.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(
            _curtPos!.latitude,
            _curtPos!.longitude,
          ),
          zoom: 18.0,
        )
      )
    );
  }

  void _onCategorySelected(
    CategorySelected event,
    Emitter<TrackingState> emit,
  ) {
    emit(state.copyWith(category: event.category));
  }

  void initTrackingSession() {
    if(state.category.isWalking) {
      activity = WalkingActivity();
    }else if(state.category.isRunning) {
      activity = RunningActivity();
    }else if(state.category.isCycling) {
      activity = CyclingActivity();
    }
  }

  Future<void> _onTrackingStarted(
    TrackingStarted event,
    Emitter<TrackingState> emit,
  ) async {
    if(_isProcessing) return;
    _isProcessing = true;
    await handleLocationPermission(emit);
    if(_locAccuracyStatus == LocationAccuracyStatus.precise) {
      if(_curtPos == null) {
        await _onDesiredLocation();
      }
      _geoPoints.add(LatLng(_curtPos!.latitude, _curtPos!.longitude));
      _updateLatLngBounds(_curtPos!);
      final pos = _curtPos!;
      final startingMarker = await _setCustomMarkers();
      _timer = _initializeTimer();
      _markers.add(Marker(
        markerId: const MarkerId("starting_position"),
        position: LatLng(pos.latitude, pos.longitude),
        icon: startingMarker,
      ));
      initTrackingSession();
      activity!.startTracking((positions) {
        if(_geoPoints.isEmpty) {
          positions.removeAt(0);
        }
        if(positions.length == 1) {
          _lastKnownPos = _curtPos;
          _curtPos = positions.first;
        }else {
          _lastKnownPos = positions[positions.length-2];
          _curtPos = positions.last;
        }
        _geoPoints.addAll(positions.map((p) {
          _updateLatLngBounds(p);
          return LatLng(p.latitude, p.longitude);
        }));
        add(const LocationUpdated());
      });
      emit(state.copyWith(
        geoPoints: _geoPoints,
        markers: _markers,
        timeStream: _timeStreamController.stream,
        status: TrackingStatus.started,
        trackingParams: TrackingParams(
          selectedTarget: state.trackingParams.selectedTarget,
          targetValue: event.targetValue,
        ),
      ));
    }
    _isProcessing = false;
  }

  void _onTrackingPaused(           
    TrackingPaused event, 
    Emitter<TrackingState> emit,
  ) {
    backgroundService.invoke("trackingPaused");
    _timer.cancel();
    emit(state.copyWith(status: TrackingStatus.paused));
  }

  Future<void> _onTrackingResumed(
    TrackingResumed event,
    Emitter<TrackingState> emit,
  ) async {
    if(_isProcessing) return;
    _isProcessing = true;
    final response = await _locationService.requestPermission();
    if (!response.isServiceEnabled) {
      _isProcessing = false;
      return emit(state.copyWith(
        request: LocationSettingsRequest.serviceEnabled(),
      ));
    } else if (response.isDeniedForever) {
      _isProcessing = false;
      return emit(state.copyWith(
        request: LocationSettingsRequest.permissionGranted(),
      ));
    }
    if (response.isPrecise) {
      if(_curtPos == null) {
        await _onDesiredLocation();
      }else {
        backgroundService.invoke("trackingResumed");
      }
      _timer = _initializeTimer();
      emit(state.copyWith(status: TrackingStatus.started));
    }
    _isProcessing = false;
  }

  Future<void> _onTrackingFinished(
    TrackingFinished event, 
    Emitter<TrackingState> emit,
  ) async {
    // final record = ActivityRecord(
    //   category: state.category,
    //   startDate: _startDate!,
    //   endDate: DateTime.now(),
    //   workoutDuration: _secondsElapsed,
    //   distance: _totalDistance,
    //   avgSpeed: _avgSpeed!,
    //   maxSpeed: _maxSpeed,
    //   avgPace: _avgPace!,
    //   maxPace: _maxPace,
    //   calories: _calories,
    //   data: _workoutData,
    //   steps: 0,
    //   stairsClimbed: 0,
    // );
    final record = ActivityRecord.empty();

    emit(state.copyWith(
      result: TrackingResult(
        geoPoints: _geoPoints,
        photosParams: _photosParams,
        record: record,
        controller: _mapController,
        latLngBounds: LatLngBounds(
          northeast: LatLng(_topMost, _rightMost),
          southwest: LatLng(_bottomMost, _leftMost),
        ),
      ),
    ));
  }

  void _destroyTrackingSession() {
    _geoPoints.clear();
    _markers.clear();
    _photosParams.clear();
    _timer.cancel();
    _secondsElapsed = 0;
    _topMost = -double.maxFinite;
    _rightMost = -double.maxFinite;
    _leftMost = double.maxFinite;
    _bottomMost = double.maxFinite;
    activeTimer?.cancel();
  }

  void onMapCreated(GoogleMapController controller) {
    _mapController.complete(controller);
  }

  void _onPhotoDeleted(
    PhotoDeleted event,
    Emitter<TrackingState> emit,
  ) {
    final photo = event.file;
    // final name = MyUtils.getFileName(photo);
    photo.deleteSync();
    // for(final m in _markers) {
    //   if(m.markerId.value == name) {
    //     _markers.remove(m);
    //     break;
    //   }
    // }
    for(final p in _photosParams) {
      if(p.file.hashCode == photo.hashCode) {
        _photosParams.remove(p);
        break;
      }
    }
    emit(state.copyWith());
  }

  void _onRefreshTracking(
    RefreshTracking event,
    Emitter<TrackingState> emit,
  ) {
    emit(state.copyWith());
  }

  void _onPhotoEdited(
    PhotoEdited event,
    Emitter<TrackingState> emit,
  ) {
    // final original = event.originalFile;
    // final editedBytes = event.editedBytes;
    // original.writeAsBytesSync(editedBytes);
    // final name = MyUtils.getFileName(original);
    // for(final m in _markers) {
    //   if(m.markerId.value == name) {
    //     _markers.remove(m);
    //     MarkerPainter.getMarkerBytes(editedBytes).then((value) {
    //       _markers.add(Marker(
    //         markerId: MarkerId(name),
    //         position: LatLng(m.position.latitude, m.position.longitude),
    //         icon: BitmapDescriptor.fromBytes(value),
    //         onTap: () => add(PhotoMarkerTapped(original)),
    //       ));
    //     });
    //     break;
    //   }
    // }
  }
 
  void _onPhotoMarkerTapped(
    PhotoMarkerTapped event,
    Emitter<TrackingState> emit,
  ) {
    emit(state.copyWith(photo: event.photo));
  }

  void _onLocationUpdated(
    LocationUpdated event,
    Emitter<TrackingState> emit,
  ) {
    emit(state.copyWith(
      trackingParams: state.trackingParams.copyWith(
        distance: activity!.totalDistance,
        speed: activity!.instantSpeed,
        avgSpeed: activity!.avgSpeed,
        pace: activity!.instantPace,
        avgPace: activity!.avgPace,
        calories: activity!.totalCalories,
      )
    ));
  }

  Future<void> _onTrackingSaved(
    TrackingSaved event,
    Emitter<TrackingState> emit,
  ) async {
    if(!event.isSuccess) return;
    _destroyTrackingSession();
    emit(const TrackingState());
  }

  void _onDropDownItemSelected(
    DropDownItemSelected event, 
    Emitter<TrackingState> emit,
  ) {
    emit(state.copyWith(
      trackingParams: TrackingParams(
        selectedTarget: event.selectedItem,
      ),
    ));
  }

  Future<void> _onPictureTaken(
    PictureTaken event,
    Emitter<TrackingState> emit,
  ) async {
    final params = event.params;
    _photosParams.add(params);
    final pictureBytes = await params.file.readAsBytes();
    final markerBytes = await MarkerPainter.getMarkerBytes(pictureBytes);
    // final fileName = MyUtils.getFileName(params.file);
    _markers.add(Marker(
      markerId: MarkerId(params.file.name),
      position: LatLng(params.latitude, params.longitude),
      icon: BitmapDescriptor.fromBytes(markerBytes),
      onTap: () => add(PhotoMarkerTapped(io.File(params.file.path))),
    ));
    emit(state.copyWith());
  }

  Future<BitmapDescriptor> _setCustomMarkers() async {
    return BitmapDescriptor.fromAssetImage(
      ImageConfiguration.empty, 
      "assets/images/start_marker.png",
    );
  }

  void _updateLatLngBounds(Position position) {
    _topMost = math.max(_topMost, position.latitude);
    _rightMost = math.max(_rightMost, position.longitude);
    _bottomMost = math.min(_bottomMost, position.latitude);
    _leftMost = math.min(_leftMost, position.longitude);
  }

  Timer _initializeTimer() {
    return Timer.periodic(const Duration(seconds: 1), (timer) {
      _secondsElapsed++;
      _timeStreamController.add(_secondsElapsed);
    });
  }

  @override
  Future<void> close() async {
    await _positionSubscriber?.cancel();
    await _activitySubscriber?.cancel();
    await _timeStreamController.close();
    WidgetsBinding.instance.removeObserver(this);
    // backgroundService.invoke("trackingStopped");
    return super.close();
  }
}