part of 'activity_tracking_bloc.dart';

@immutable
abstract class ActivityTrackingEvent {
  const ActivityTrackingEvent();
}

class TrackingStarted extends ActivityTrackingEvent {
  final double? targetValue;
  const TrackingStarted(this.targetValue);
}

class TrackingPaused extends ActivityTrackingEvent {
  const TrackingPaused();
}

class TrackingResumed extends ActivityTrackingEvent {
  const TrackingResumed();
}

class TrackingFinished extends ActivityTrackingEvent {
  const TrackingFinished();
}

class TrackingSaved extends ActivityTrackingEvent {
  final bool isSuccess;
  const TrackingSaved(this.isSuccess);
}

class LocationUpdated extends ActivityTrackingEvent {
  const LocationUpdated();
}

class PhotoMarkerTapped extends ActivityTrackingEvent {
  final io.File? photo;
  const PhotoMarkerTapped(this.photo);
}

class PictureTaken extends ActivityTrackingEvent {
  final PhotoParams params;
  const PictureTaken(this.params);
}

class PhotoDeleted extends ActivityTrackingEvent {
  final io.File file;
  const PhotoDeleted(this.file);
}

class DropDownItemSelected extends ActivityTrackingEvent {
  final TrackingTarget selectedItem;
  const DropDownItemSelected(this.selectedItem);
}

class PhotoEdited extends ActivityTrackingEvent {
  final io.File originalFile;
  final Uint8List editedBytes;

  const PhotoEdited(this.originalFile, this.editedBytes);
}

class RefreshTracking extends ActivityTrackingEvent {
  const RefreshTracking();
}