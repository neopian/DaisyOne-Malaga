import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../../core/geo/spain_geo.dart';
import '../../core/services/location_service.dart';
import '../../core/utils/formatters.dart';
import '../../shared/models/app_user.dart';
import '../../shared/models/question.dart';
import '../../shared/widgets/app_drawer.dart';
import '../../shared/widgets/status_chip.dart';
import '../profile/profile_repository.dart';
import 'question_repository.dart';

const _currentLocationZoom = 13.0;

class QuestionHomePage extends ConsumerStatefulWidget {
  const QuestionHomePage({super.key});

  @override
  ConsumerState<QuestionHomePage> createState() => _QuestionHomePageState();
}

class _QuestionHomePageState extends ConsumerState<QuestionHomePage> {
  late final MapController _mapController;
  Future<DeviceCoordinates?>? _currentLocationRequest;
  DeviceCoordinates? _pendingCameraMove;
  DeviceCoordinates? _currentCoordinates;
  LatLngBounds? _visibleBounds;
  bool _isMapReady = false;
  bool _isResolvingLocation = false;
  String? _locationError;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshCurrentLocation(moveCamera: true);
    });
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  Future<DeviceCoordinates?> _refreshCurrentLocation({
    bool moveCamera = false,
  }) {
    final activeRequest = _currentLocationRequest;
    if (activeRequest != null) {
      return activeRequest.then((coordinates) {
        if (moveCamera && coordinates != null && mounted) {
          _moveMapToCoordinates(coordinates);
        }
        return coordinates;
      });
    }

    final request = _resolveCurrentLocation(moveCamera: moveCamera);
    _currentLocationRequest = request;
    return request.whenComplete(() {
      if (identical(_currentLocationRequest, request)) {
        _currentLocationRequest = null;
      }
    });
  }

  Future<DeviceCoordinates?> _resolveCurrentLocation({
    required bool moveCamera,
  }) async {
    setState(() {
      _isResolvingLocation = true;
      _locationError = null;
    });
    try {
      final coordinates = await const LocationService().getCurrentCoordinates();
      if (!mounted) return null;
      final shouldResetBounds =
          _mapIdentity(_currentCoordinates) != _mapIdentity(coordinates);
      setState(() {
        _currentCoordinates = coordinates;
        if (shouldResetBounds) _visibleBounds = null;
      });
      if (moveCamera) _moveMapToCoordinates(coordinates);
      return coordinates;
    } catch (error) {
      if (!mounted) return null;
      setState(() => _locationError = _locationMessage(error));
      return null;
    } finally {
      if (mounted) setState(() => _isResolvingLocation = false);
    }
  }

  void _refreshData() {
    ref.invalidate(questionsProvider);
    ref.invalidate(currentProfileProvider);
    _refreshCurrentLocation();
  }

  Future<void> _moveToCurrentLocation() async {
    final coordinates = await _refreshCurrentLocation(moveCamera: true);
    if (!mounted || coordinates != null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_locationError ?? '현재 위치를 확인하지 못했습니다.')),
    );
  }

  void _moveMapToCoordinates(DeviceCoordinates coordinates) {
    _pendingCameraMove = coordinates;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _flushPendingCameraMove();
    });
  }

  void _flushPendingCameraMove() {
    if (!_isMapReady) return;
    final coordinates = _pendingCameraMove;
    if (coordinates == null) return;
    _pendingCameraMove = null;
    try {
      _mapController.move(
        LatLng(coordinates.latitude, coordinates.longitude),
        _currentLocationZoom,
      );
    } catch (_) {
      _pendingCameraMove = coordinates;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _flushPendingCameraMove();
      });
    }
  }

  void _handleMapReady(String mapIdentity, LatLngBounds bounds) {
    _isMapReady = true;
    _handleVisibleBoundsChanged(mapIdentity, bounds);
    _flushPendingCameraMove();
  }

  String _locationMessage(Object error) {
    return error.toString().replaceFirst('Bad state: ', '');
  }

  @override
  Widget build(BuildContext context) {
    final questions = ref.watch(questionsProvider);
    final profile = ref.watch(currentProfileProvider).asData?.value;
    final items = questions.asData?.value ?? const <Question>[];
    final visibleItems = _visibleQuestions(items);
    final isLoading =
        (questions.isLoading && !questions.hasValue) || _visibleBounds == null;

    return Scaffold(
      drawer: const AppDrawer(),
      body: Stack(
        children: [
          Positioned.fill(
            child: _MapSurface(
              mapController: _mapController,
              questions: items,
              currentCoordinates: _currentCoordinates,
              onMapReady: _handleMapReady,
              onVisibleBoundsChanged: _handleVisibleBoundsChanged,
            ),
          ),
          _MapTopBar(
            profile: profile,
            isLoading: isLoading || _isResolvingLocation,
            hasCurrentLocation: _currentCoordinates != null,
            onRefresh: _refreshData,
            onSwitchRole: () => context.go('/helper/home'),
          ),
          if (questions.hasError)
            Positioned(
              left: 16,
              right: 16,
              top: MediaQuery.paddingOf(context).top + 86,
              child: _MapNotice(message: questions.error.toString()),
            ),
          if (!questions.hasError &&
              items.any(
                (question) =>
                    question.latitude == null || question.longitude == null,
              ))
            const _NoCoordinateBanner(),
          if (_locationError != null)
            Positioned(
              left: 16,
              right: 16,
              top: MediaQuery.paddingOf(context).top + 144,
              child: _MapNotice(message: _locationError!),
            ),
          _QuestionSheet(questions: visibleItems, isLoading: isLoading),
          Positioned(
            right: 18,
            bottom: 264,
            child: _CircleMapButton(
              tooltip: '현재 위치로 이동',
              icon: _isResolvingLocation ? Icons.sync : Icons.my_location,
              onTap: _moveToCurrentLocation,
            ),
          ),
          Positioned(
            right: 18,
            bottom: 196,
            child: _MapActionButton(
              tooltip: '질문하기',
              icon: Icons.add,
              label: '질문',
              onTap: () => context.go('/questions/new'),
            ),
          ),
        ],
      ),
    );
  }

  List<Question> _visibleQuestions(List<Question> questions) {
    final bounds = _visibleBounds;
    if (bounds == null) return const <Question>[];
    return questions.where((question) {
      final latitude = question.latitude;
      final longitude = question.longitude;
      if (latitude == null || longitude == null) return false;
      return bounds.contains(LatLng(latitude, longitude));
    }).toList();
  }

  void _handleVisibleBoundsChanged(String mapIdentity, LatLngBounds bounds) {
    if (mapIdentity != _mapIdentity(_currentCoordinates)) return;
    final current = _visibleBounds;
    if (current != null && _sameBounds(current, bounds)) return;
    if (!mounted) return;
    setState(() => _visibleBounds = bounds);
  }

  bool _sameBounds(LatLngBounds a, LatLngBounds b) {
    const tolerance = 0.0001;
    return (a.north - b.north).abs() < tolerance &&
        (a.south - b.south).abs() < tolerance &&
        (a.east - b.east).abs() < tolerance &&
        (a.west - b.west).abs() < tolerance;
  }
}

String _mapIdentity(DeviceCoordinates? coordinates) {
  if (coordinates == null) return 'spain-map';
  return 'spain-map-${coordinates.latitude.toStringAsFixed(4)}-${coordinates.longitude.toStringAsFixed(4)}';
}

const _mapLabelLocale = 'ko';
const _questionClusterMaxZoom = 8.0;
const _wholeMapClusterMaxZoom = 6.5;

typedef _VisibleBoundsChanged =
    void Function(String mapIdentity, LatLngBounds bounds);

class QuestionCard extends StatelessWidget {
  const QuestionCard({super.key, required this.question});

  final Question question;

  @override
  Widget build(BuildContext context) {
    return _NearbyQuestionTile(question: question);
  }
}

class _MapTopBar extends StatelessWidget {
  const _MapTopBar({
    required this.profile,
    required this.isLoading,
    required this.hasCurrentLocation,
    required this.onRefresh,
    required this.onSwitchRole,
  });

  final AppUser? profile;
  final bool isLoading;
  final bool hasCurrentLocation;
  final VoidCallback onRefresh;
  final VoidCallback onSwitchRole;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final location = _profileLocation(profile);

    return Positioned(
      left: 16,
      right: 16,
      top: padding.top + 12,
      child: Row(
        children: [
          _CircleMapButton(
            tooltip: '메뉴',
            icon: Icons.menu,
            onTap: () => Scaffold.of(context).openDrawer(),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => context.go('/questions/new'),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x260B2B34),
                      blurRadius: 22,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.search, color: Color(0xFF13857E)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '어디가 궁금하세요?',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              hasCurrentLocation
                                  ? '현재 위치가 지도에 표시됩니다'
                                  : location,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: const Color(0xFF60726F)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _CircleMapButton(
            tooltip: '새로고침',
            icon: isLoading ? Icons.sync : Icons.refresh,
            onTap: onRefresh,
          ),
          const SizedBox(width: 8),
          _CircleMapButton(
            tooltip: '답변자로 전환',
            icon: Icons.support_agent_outlined,
            onTap: onSwitchRole,
          ),
        ],
      ),
    );
  }

  static String _profileLocation(AppUser? profile) {
    final country = profile?.currentCountry?.trim() ?? '';
    final city = profile?.currentCity?.trim() ?? '';
    if (country.isEmpty && city.isEmpty) return '현재 위치 기준으로 질문을 찾아요';
    return [country, city].where((value) => value.isNotEmpty).join(' ');
  }
}

class _MapSurface extends StatelessWidget {
  const _MapSurface({
    required this.mapController,
    required this.questions,
    required this.currentCoordinates,
    required this.onMapReady,
    required this.onVisibleBoundsChanged,
  });

  final MapController mapController;
  final List<Question> questions;
  final DeviceCoordinates? currentCoordinates;
  final _VisibleBoundsChanged onMapReady;
  final _VisibleBoundsChanged onVisibleBoundsChanged;

  @override
  Widget build(BuildContext context) {
    final currentCoordinates = this.currentCoordinates;
    final mapIdentity = _mapIdentity(currentCoordinates);

    return FlutterMap(
      mapController: mapController,
      options: MapOptions(
        initialCenter: currentCoordinates == null
            ? const LatLng(SpainGeo.defaultLatitude, SpainGeo.defaultLongitude)
            : LatLng(currentCoordinates.latitude, currentCoordinates.longitude),
        initialZoom: currentCoordinates == null ? 5.8 : _currentLocationZoom,
        minZoom: 5,
        maxZoom: 17,
        cameraConstraint: CameraConstraint.containCenter(
          bounds: LatLngBounds(
            const LatLng(SpainGeo.minLatitude, SpainGeo.minLongitude),
            const LatLng(SpainGeo.maxLatitude, SpainGeo.maxLongitude),
          ),
        ),
        interactionOptions: const InteractionOptions(
          flags:
              InteractiveFlag.drag |
              InteractiveFlag.flingAnimation |
              InteractiveFlag.pinchMove |
              InteractiveFlag.pinchZoom |
              InteractiveFlag.doubleTapZoom |
              InteractiveFlag.scrollWheelZoom,
        ),
        onMapReady: () {
          onMapReady(mapIdentity, mapController.camera.visibleBounds);
        },
        onPositionChanged: (camera, _) {
          onVisibleBoundsChanged(mapIdentity, camera.visibleBounds);
        },
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'local_qa_concierge',
        ),
        Builder(
          builder: (context) {
            final camera = MapCamera.of(context);
            return MarkerLayer(
              markers: _localizedMapLabelMarkers(
                zoom: camera.zoom,
                locale: _mapLabelLocale,
              ),
            );
          },
        ),
        Builder(
          builder: (context) {
            final camera = MapCamera.of(context);
            final markers = _questionMarkersForZoom(
              mapController: mapController,
              questions: questions,
              zoom: camera.zoom,
              visibleBounds: camera.visibleBounds,
            );
            if (camera.zoom >= _questionClusterMaxZoom) {
              final locationMarker = _currentLocationMarker(currentCoordinates);
              if (locationMarker != null) markers.add(locationMarker);
            }
            return MarkerLayer(markers: markers);
          },
        ),
        RichAttributionWidget(
          attributions: [
            TextSourceAttribution('OpenStreetMap contributors', onTap: () {}),
          ],
        ),
      ],
    );
  }
}

List<Marker> _questionMarkersForZoom({
  required MapController mapController,
  required List<Question> questions,
  required double zoom,
  required LatLngBounds visibleBounds,
}) {
  final visibleQuestions = questions.where((question) {
    final latitude = question.latitude;
    final longitude = question.longitude;
    if (latitude == null || longitude == null) return false;
    return visibleBounds.contains(LatLng(latitude, longitude));
  }).toList();

  if (zoom < _questionClusterMaxZoom) {
    return _clusteredQuestionMarkers(
      mapController: mapController,
      questions: visibleQuestions,
      zoom: zoom,
    );
  }

  return visibleQuestions
      .map(
        (question) => Marker(
          point: LatLng(question.latitude!, question.longitude!),
          width: 118,
          height: 72,
          alignment: Alignment.topCenter,
          child: _QuestionPin(question: question),
        ),
      )
      .toList();
}

List<Marker> _clusteredQuestionMarkers({
  required MapController mapController,
  required List<Question> questions,
  required double zoom,
}) {
  final buckets = <String, _QuestionClusterBucket>{};
  for (final question in questions) {
    final latitude = question.latitude;
    final longitude = question.longitude;
    if (latitude == null || longitude == null) continue;
    final key = _questionClusterKey(
      latitude: latitude,
      longitude: longitude,
      zoom: zoom,
    );
    (buckets[key] ??= _QuestionClusterBucket()).add(
      latitude: latitude,
      longitude: longitude,
    );
  }

  return buckets.values.map((bucket) {
    final center = bucket.center;
    final markerSize = _clusterMarkerSize(bucket.count);
    return Marker(
      point: center,
      width: markerSize,
      height: markerSize,
      alignment: Alignment.center,
      child: _QuestionClusterMarker(
        count: bucket.count,
        onTap: () {
          final nextZoom = (zoom + 2.4)
              .clamp(_questionClusterMaxZoom + .4, 12.0)
              .toDouble();
          mapController.move(center, nextZoom);
        },
      ),
    );
  }).toList();
}

String _questionClusterKey({
  required double latitude,
  required double longitude,
  required double zoom,
}) {
  if (zoom < _wholeMapClusterMaxZoom) return 'visible-map';

  final cellSize = zoom < 7.3 ? 3.6 : 1.4;
  final latitudeCell = (latitude / cellSize).floor();
  final longitudeCell = (longitude / cellSize).floor();
  return '$latitudeCell:$longitudeCell';
}

double _clusterMarkerSize(int count) {
  if (count >= 100) return 74;
  if (count >= 10) return 66;
  return 58;
}

Marker? _currentLocationMarker(DeviceCoordinates? currentCoordinates) {
  if (currentCoordinates == null) return null;
  return Marker(
    point: LatLng(currentCoordinates.latitude, currentCoordinates.longitude),
    width: 70,
    height: 70,
    alignment: Alignment.center,
    child: const _CurrentLocationMarker(),
  );
}

class _QuestionClusterBucket {
  int count = 0;
  double _latitudeSum = 0;
  double _longitudeSum = 0;

  void add({required double latitude, required double longitude}) {
    count += 1;
    _latitudeSum += latitude;
    _longitudeSum += longitude;
  }

  LatLng get center {
    return LatLng(_latitudeSum / count, _longitudeSum / count);
  }
}

List<Marker> _localizedMapLabelMarkers({
  required double zoom,
  required String locale,
}) {
  return _localizedMapPlaces
      .where((place) => place.tier.isVisibleAt(zoom))
      .map(
        (place) => Marker(
          point: LatLng(place.latitude, place.longitude),
          width: place.tier.width,
          height: place.tier.height,
          alignment: Alignment.center,
          child: IgnorePointer(
            child: _LocalizedMapLabel(
              label: place.labelFor(locale),
              tier: place.tier,
            ),
          ),
        ),
      )
      .toList();
}

class _LocalizedMapLabel extends StatelessWidget {
  const _LocalizedMapLabel({required this.label, required this.tier});

  final String label;
  final _LocalizedMapLabelTier tier;

  @override
  Widget build(BuildContext context) {
    final color = tier.foregroundColor;
    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tier.backgroundColor,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: tier.borderColor),
          boxShadow: const [
            BoxShadow(
              color: Color(0x22000000),
              blurRadius: 5,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: Padding(
          padding: tier.padding,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              style: TextStyle(
                color: color,
                fontSize: tier.fontSize,
                fontWeight: tier.fontWeight,
                height: 1.05,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LocalizedMapPlace {
  const _LocalizedMapPlace({
    required this.latitude,
    required this.longitude,
    required this.tier,
    required this.labels,
  });

  final double latitude;
  final double longitude;
  final _LocalizedMapLabelTier tier;
  final Map<String, String> labels;

  String labelFor(String locale) {
    return labels[locale] ?? labels['native'] ?? labels.values.first;
  }
}

enum _LocalizedMapLabelTier { country, region, city, local }

extension _LocalizedMapLabelTierStyle on _LocalizedMapLabelTier {
  bool isVisibleAt(double zoom) {
    return zoom >= minZoom && zoom <= maxZoom;
  }

  double get minZoom {
    return switch (this) {
      _LocalizedMapLabelTier.country => 4.8,
      _LocalizedMapLabelTier.region => 5.3,
      _LocalizedMapLabelTier.city => 6.7,
      _LocalizedMapLabelTier.local => 9.2,
    };
  }

  double get maxZoom {
    return switch (this) {
      _LocalizedMapLabelTier.country => 6.4,
      _LocalizedMapLabelTier.region => 8.6,
      _LocalizedMapLabelTier.city => 17.1,
      _LocalizedMapLabelTier.local => 17.1,
    };
  }

  double get width {
    return switch (this) {
      _LocalizedMapLabelTier.country => 96,
      _LocalizedMapLabelTier.region => 128,
      _LocalizedMapLabelTier.city => 118,
      _LocalizedMapLabelTier.local => 132,
    };
  }

  double get height {
    return switch (this) {
      _LocalizedMapLabelTier.country => 34,
      _LocalizedMapLabelTier.region => 30,
      _LocalizedMapLabelTier.city => 28,
      _LocalizedMapLabelTier.local => 26,
    };
  }

  double get fontSize {
    return switch (this) {
      _LocalizedMapLabelTier.country => 18,
      _LocalizedMapLabelTier.region => 14,
      _LocalizedMapLabelTier.city => 13,
      _LocalizedMapLabelTier.local => 12,
    };
  }

  FontWeight get fontWeight {
    return switch (this) {
      _LocalizedMapLabelTier.country => FontWeight.w900,
      _LocalizedMapLabelTier.region => FontWeight.w800,
      _LocalizedMapLabelTier.city => FontWeight.w800,
      _LocalizedMapLabelTier.local => FontWeight.w700,
    };
  }

  EdgeInsets get padding {
    return switch (this) {
      _LocalizedMapLabelTier.country => const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 5,
      ),
      _LocalizedMapLabelTier.region => const EdgeInsets.symmetric(
        horizontal: 8,
        vertical: 4,
      ),
      _LocalizedMapLabelTier.city => const EdgeInsets.symmetric(
        horizontal: 7,
        vertical: 4,
      ),
      _LocalizedMapLabelTier.local => const EdgeInsets.symmetric(
        horizontal: 7,
        vertical: 3,
      ),
    };
  }

  Color get foregroundColor {
    return switch (this) {
      _LocalizedMapLabelTier.country => const Color(0xFF0F3D38),
      _LocalizedMapLabelTier.region => const Color(0xFF34524D),
      _LocalizedMapLabelTier.city => const Color(0xFF17211F),
      _LocalizedMapLabelTier.local => const Color(0xFF45524F),
    };
  }

  Color get backgroundColor {
    return switch (this) {
      _LocalizedMapLabelTier.country => const Color(0xF4E9FBF7),
      _LocalizedMapLabelTier.region => const Color(0xEFFFFFFF),
      _LocalizedMapLabelTier.city => const Color(0xEEFFFFFF),
      _LocalizedMapLabelTier.local => const Color(0xDFFFFFFF),
    };
  }

  Color get borderColor {
    return switch (this) {
      _LocalizedMapLabelTier.country => const Color(0x6610B6A5),
      _LocalizedMapLabelTier.region => const Color(0x6692A9A3),
      _LocalizedMapLabelTier.city => const Color(0x668FA49F),
      _LocalizedMapLabelTier.local => const Color(0x558FA49F),
    };
  }
}

const _localizedMapPlaces = [
  _LocalizedMapPlace(
    latitude: 40.2,
    longitude: -3.5,
    tier: _LocalizedMapLabelTier.country,
    labels: {'ko': '스페인', 'native': 'España'},
  ),
  _LocalizedMapPlace(
    latitude: 37.45,
    longitude: -4.75,
    tier: _LocalizedMapLabelTier.region,
    labels: {'ko': '안달루시아', 'native': 'Andalucía'},
  ),
  _LocalizedMapPlace(
    latitude: 41.82,
    longitude: 1.45,
    tier: _LocalizedMapLabelTier.region,
    labels: {'ko': '카탈루냐', 'native': 'Catalunya'},
  ),
  _LocalizedMapPlace(
    latitude: 39.45,
    longitude: -0.72,
    tier: _LocalizedMapLabelTier.region,
    labels: {'ko': '발렌시아주', 'native': 'Comunitat Valenciana'},
  ),
  _LocalizedMapPlace(
    latitude: 39.58,
    longitude: -3.0,
    tier: _LocalizedMapLabelTier.region,
    labels: {'ko': '카스티야라만차', 'native': 'Castilla-La Mancha'},
  ),
  _LocalizedMapPlace(
    latitude: 41.75,
    longitude: -4.78,
    tier: _LocalizedMapLabelTier.region,
    labels: {'ko': '카스티야이레온', 'native': 'Castilla y León'},
  ),
  _LocalizedMapPlace(
    latitude: 42.82,
    longitude: -7.9,
    tier: _LocalizedMapLabelTier.region,
    labels: {'ko': '갈리시아', 'native': 'Galicia'},
  ),
  _LocalizedMapPlace(
    latitude: 43.08,
    longitude: -2.62,
    tier: _LocalizedMapLabelTier.region,
    labels: {'ko': '바스크', 'native': 'Euskadi'},
  ),
  _LocalizedMapPlace(
    latitude: 41.35,
    longitude: -0.66,
    tier: _LocalizedMapLabelTier.region,
    labels: {'ko': '아라곤', 'native': 'Aragón'},
  ),
  _LocalizedMapPlace(
    latitude: 37.95,
    longitude: -1.55,
    tier: _LocalizedMapLabelTier.region,
    labels: {'ko': '무르시아', 'native': 'Región de Murcia'},
  ),
  _LocalizedMapPlace(
    latitude: 39.05,
    longitude: -6.25,
    tier: _LocalizedMapLabelTier.region,
    labels: {'ko': '엑스트레마두라', 'native': 'Extremadura'},
  ),
  _LocalizedMapPlace(
    latitude: 43.35,
    longitude: -5.9,
    tier: _LocalizedMapLabelTier.region,
    labels: {'ko': '아스투리아스', 'native': 'Asturias'},
  ),
  _LocalizedMapPlace(
    latitude: 39.6,
    longitude: 2.92,
    tier: _LocalizedMapLabelTier.region,
    labels: {'ko': '발레아레스 제도', 'native': 'Illes Balears'},
  ),
  _LocalizedMapPlace(
    latitude: 28.35,
    longitude: -15.9,
    tier: _LocalizedMapLabelTier.region,
    labels: {'ko': '카나리아 제도', 'native': 'Canarias'},
  ),
  _LocalizedMapPlace(
    latitude: 40.4168,
    longitude: -3.7038,
    tier: _LocalizedMapLabelTier.city,
    labels: {'ko': '마드리드', 'native': 'Madrid'},
  ),
  _LocalizedMapPlace(
    latitude: 41.3874,
    longitude: 2.1686,
    tier: _LocalizedMapLabelTier.city,
    labels: {'ko': '바르셀로나', 'native': 'Barcelona'},
  ),
  _LocalizedMapPlace(
    latitude: 39.4699,
    longitude: -0.3763,
    tier: _LocalizedMapLabelTier.city,
    labels: {'ko': '발렌시아', 'native': 'Valencia'},
  ),
  _LocalizedMapPlace(
    latitude: 37.3891,
    longitude: -5.9845,
    tier: _LocalizedMapLabelTier.city,
    labels: {'ko': '세비야', 'native': 'Sevilla'},
  ),
  _LocalizedMapPlace(
    latitude: 41.6488,
    longitude: -0.8891,
    tier: _LocalizedMapLabelTier.city,
    labels: {'ko': '사라고사', 'native': 'Zaragoza'},
  ),
  _LocalizedMapPlace(
    latitude: 36.7213,
    longitude: -4.4214,
    tier: _LocalizedMapLabelTier.city,
    labels: {'ko': '말라가', 'native': 'Málaga'},
  ),
  _LocalizedMapPlace(
    latitude: 37.9922,
    longitude: -1.1307,
    tier: _LocalizedMapLabelTier.city,
    labels: {'ko': '무르시아', 'native': 'Murcia'},
  ),
  _LocalizedMapPlace(
    latitude: 39.5696,
    longitude: 2.6502,
    tier: _LocalizedMapLabelTier.city,
    labels: {'ko': '팔마', 'native': 'Palma'},
  ),
  _LocalizedMapPlace(
    latitude: 43.263,
    longitude: -2.935,
    tier: _LocalizedMapLabelTier.city,
    labels: {'ko': '빌바오', 'native': 'Bilbao'},
  ),
  _LocalizedMapPlace(
    latitude: 38.3452,
    longitude: -0.481,
    tier: _LocalizedMapLabelTier.city,
    labels: {'ko': '알리칸테', 'native': 'Alicante'},
  ),
  _LocalizedMapPlace(
    latitude: 37.8882,
    longitude: -4.7794,
    tier: _LocalizedMapLabelTier.city,
    labels: {'ko': '코르도바', 'native': 'Córdoba'},
  ),
  _LocalizedMapPlace(
    latitude: 37.1773,
    longitude: -3.5986,
    tier: _LocalizedMapLabelTier.city,
    labels: {'ko': '그라나다', 'native': 'Granada'},
  ),
  _LocalizedMapPlace(
    latitude: 36.5297,
    longitude: -6.2926,
    tier: _LocalizedMapLabelTier.city,
    labels: {'ko': '카디스', 'native': 'Cádiz'},
  ),
  _LocalizedMapPlace(
    latitude: 36.834,
    longitude: -2.4637,
    tier: _LocalizedMapLabelTier.city,
    labels: {'ko': '알메리아', 'native': 'Almería'},
  ),
  _LocalizedMapPlace(
    latitude: 37.7796,
    longitude: -3.7849,
    tier: _LocalizedMapLabelTier.city,
    labels: {'ko': '하엔', 'native': 'Jaén'},
  ),
  _LocalizedMapPlace(
    latitude: 36.5101,
    longitude: -4.8824,
    tier: _LocalizedMapLabelTier.local,
    labels: {'ko': '마르베야', 'native': 'Marbella'},
  ),
  _LocalizedMapPlace(
    latitude: 36.5988,
    longitude: -4.5168,
    tier: _LocalizedMapLabelTier.local,
    labels: {'ko': '토레몰리노스', 'native': 'Torremolinos'},
  ),
  _LocalizedMapPlace(
    latitude: 36.5966,
    longitude: -4.5727,
    tier: _LocalizedMapLabelTier.local,
    labels: {'ko': '베날마데나', 'native': 'Benalmádena'},
  ),
  _LocalizedMapPlace(
    latitude: 36.539,
    longitude: -4.6244,
    tier: _LocalizedMapLabelTier.local,
    labels: {'ko': '푸엔히롤라', 'native': 'Fuengirola'},
  ),
  _LocalizedMapPlace(
    latitude: 36.596,
    longitude: -4.6373,
    tier: _LocalizedMapLabelTier.local,
    labels: {'ko': '미하스', 'native': 'Mijas'},
  ),
  _LocalizedMapPlace(
    latitude: 36.7465,
    longitude: -3.8794,
    tier: _LocalizedMapLabelTier.local,
    labels: {'ko': '네르하', 'native': 'Nerja'},
  ),
  _LocalizedMapPlace(
    latitude: 36.7726,
    longitude: -4.1005,
    tier: _LocalizedMapLabelTier.local,
    labels: {'ko': '벨레스말라가', 'native': 'Vélez-Málaga'},
  ),
  _LocalizedMapPlace(
    latitude: 36.7169,
    longitude: -4.2806,
    tier: _LocalizedMapLabelTier.local,
    labels: {'ko': '린콘 데 라 빅토리아', 'native': 'Rincón de la Victoria'},
  ),
  _LocalizedMapPlace(
    latitude: 36.4256,
    longitude: -5.151,
    tier: _LocalizedMapLabelTier.local,
    labels: {'ko': '에스테포나', 'native': 'Estepona'},
  ),
  _LocalizedMapPlace(
    latitude: 37.0194,
    longitude: -4.5612,
    tier: _LocalizedMapLabelTier.local,
    labels: {'ko': '안테케라', 'native': 'Antequera'},
  ),
  _LocalizedMapPlace(
    latitude: 36.7462,
    longitude: -5.1612,
    tier: _LocalizedMapLabelTier.local,
    labels: {'ko': '론다', 'native': 'Ronda'},
  ),
];

class _NoCoordinateBanner extends StatelessWidget {
  const _NoCoordinateBanner();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 16,
      right: 16,
      top: MediaQuery.paddingOf(context).top + 86,
      child: const _MapNotice(message: '이전 질문에는 좌표가 없어 지도 핀이 표시되지 않을 수 있습니다.'),
    );
  }
}

class _QuestionClusterMarker extends StatelessWidget {
  const _QuestionClusterMarker({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final displayCount = count > 99 ? '99+' : '$count';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF0F766E),
            border: Border.all(color: Colors.white, width: 4),
            boxShadow: const [
              BoxShadow(
                color: Color(0x330B2B34),
                blurRadius: 14,
                offset: Offset(0, 5),
              ),
            ],
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  displayCount,
                  maxLines: 1,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  '질문',
                  maxLines: 1,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    height: 1,
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

class _QuestionPin extends StatelessWidget {
  const _QuestionPin({required this.question});

  final Question question;

  @override
  Widget build(BuildContext context) {
    final style = _QuestionCategoryStyle.forCategory(question.category);

    return Align(
      alignment: Alignment.bottomCenter,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => context.go('/questions/${question.id}'),
        child: CustomPaint(
          painter: _QuestionBubblePainter(accentColor: style.color),
          child: SizedBox(
            width: 104,
            height: 56,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 7, 12, 18),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(style.icon, size: 18, color: style.color),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      formatPoints(question.rewardPoints),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: const Color(0xFF17211F),
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QuestionCategoryStyle {
  const _QuestionCategoryStyle({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  static _QuestionCategoryStyle forCategory(String category) {
    return switch (category) {
      '교통' => const _QuestionCategoryStyle(
        icon: Icons.directions_bus_filled_outlined,
        color: Color(0xFF2563EB),
      ),
      '번역' => const _QuestionCategoryStyle(
        icon: Icons.translate,
        color: Color(0xFF7C3AED),
      ),
      '생활' => const _QuestionCategoryStyle(
        icon: Icons.home_repair_service_outlined,
        color: Color(0xFF0F766E),
      ),
      '쇼핑' => const _QuestionCategoryStyle(
        icon: Icons.shopping_bag_outlined,
        color: Color(0xFFD97706),
      ),
      '식당' => const _QuestionCategoryStyle(
        icon: Icons.restaurant_menu,
        color: Color(0xFFDC2626),
      ),
      '긴급도움' => const _QuestionCategoryStyle(
        icon: Icons.sos_outlined,
        color: Color(0xFFE11D48),
      ),
      _ => const _QuestionCategoryStyle(
        icon: Icons.help_outline,
        color: Color(0xFF10B6A5),
      ),
    };
  }
}

class _CurrentLocationMarker extends StatelessWidget {
  const _CurrentLocationMarker();

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 58,
          height: 58,
          decoration: BoxDecoration(
            color: const Color(0x333B82F6),
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0x553B82F6), width: 1.5),
          ),
        ),
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: const Color(0xFF2563EB),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 4),
            boxShadow: const [
              BoxShadow(
                color: Color(0x442563EB),
                blurRadius: 14,
                offset: Offset(0, 4),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

const _questionSheetInitialSize = .28;
const _questionSheetMinSize = .20;
const _questionSheetMaxSize = .68;

class _QuestionSheet extends StatefulWidget {
  const _QuestionSheet({required this.questions, required this.isLoading});

  final List<Question> questions;
  final bool isLoading;

  @override
  State<_QuestionSheet> createState() => _QuestionSheetState();
}

class _QuestionSheetState extends State<_QuestionSheet> {
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  @override
  void dispose() {
    _sheetController.dispose();
    super.dispose();
  }

  void _handleDragUpdate(DragUpdateDetails details, double availableHeight) {
    if (!_sheetController.isAttached || availableHeight <= 0) return;

    final dragDelta = details.primaryDelta ?? 0;
    final nextSize = (_sheetController.size - dragDelta / availableHeight)
        .clamp(_questionSheetMinSize, _questionSheetMaxSize)
        .toDouble();
    _sheetController.jumpTo(nextSize);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return DraggableScrollableSheet(
          controller: _sheetController,
          initialChildSize: _questionSheetInitialSize,
          minChildSize: _questionSheetMinSize,
          maxChildSize: _questionSheetMaxSize,
          builder: (context, controller) {
            return DecoratedBox(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
                boxShadow: [
                  BoxShadow(
                    color: Color(0x300B2B34),
                    blurRadius: 26,
                    offset: Offset(0, -8),
                  ),
                ],
              ),
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(18, 6, 18, 28),
                children: [
                  _QuestionSheetDragHandle(
                    onDragUpdate: (details) {
                      _handleDragUpdate(details, constraints.maxHeight);
                    },
                  ),
                  const SizedBox(height: 10),
                  _SheetHeader(count: widget.questions.length),
                  const SizedBox(height: 14),
                  if (widget.isLoading)
                    const _SheetLoading()
                  else if (widget.questions.isEmpty)
                    const _EmptyMapState()
                  else
                    for (final question in widget.questions)
                      _NearbyQuestionTile(question: question),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _QuestionSheetDragHandle extends StatelessWidget {
  const _QuestionSheetDragHandle({required this.onDragUpdate});

  final GestureDragUpdateCallback onDragUpdate;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '질문 목록 크기 조절',
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeUpDown,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: onDragUpdate,
          child: SizedBox(
            height: 30,
            child: Center(
              child: Container(
                width: 70,
                height: 6,
                decoration: BoxDecoration(
                  color: const Color(0xFFD8E2DF),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '지도에 보이는 질문',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 2),
        Text(
          '현재 화면 · $count개 질문',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: const Color(0xFF60726F)),
        ),
      ],
    );
  }
}

class _NearbyQuestionTile extends StatelessWidget {
  const _NearbyQuestionTile({required this.question});

  final Question question;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: const Color(0xFFF7FAF9),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Color(0xFFE1EAE7)),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => context.go('/questions/${question.id}'),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: question.isOpen
                        ? const Color(0xFFE0FFF7)
                        : const Color(0xFFFFF3D8),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SizedBox(
                    width: 46,
                    height: 46,
                    child: Icon(
                      question.isOpen
                          ? Icons.chat_bubble_outline
                          : Icons.route_outlined,
                      color: question.isOpen
                          ? const Color(0xFF008E7C)
                          : const Color(0xFFD48100),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          StatusChip(
                            label: question.status,
                            emphasis: question.isOpen,
                          ),
                          const SizedBox(width: 6),
                          StatusChip(label: question.urgency),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        question.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        question.locationLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF60726F),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      formatPoints(question.rewardPoints),
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      formatDate(question.createdAt),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: const Color(0xFF60726F),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MapNotice extends StatelessWidget {
  const _MapNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x220B2B34),
            blurRadius: 18,
            offset: Offset(0, 7),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.info_outline, color: Color(0xFFE06F4F)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetLoading extends StatelessWidget {
  const _SheetLoading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 28),
      child: Center(child: CircularProgressIndicator()),
    );
  }
}

class _EmptyMapState extends StatelessWidget {
  const _EmptyMapState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        children: [
          const Icon(
            Icons.explore_outlined,
            size: 44,
            color: Color(0xFF10B6A5),
          ),
          const SizedBox(height: 10),
          Text(
            '현재 지도 화면에 질문이 없습니다',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            '지도를 움직이거나 확대/축소해서 다른 지역 질문을 찾아보세요.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: const Color(0xFF60726F)),
          ),
        ],
      ),
    );
  }
}

class _CircleMapButton extends StatelessWidget {
  const _CircleMapButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 6,
      shadowColor: const Color(0x260B2B34),
      child: IconButton(tooltip: tooltip, onPressed: onTap, icon: Icon(icon)),
    );
  }
}

class _MapActionButton extends StatelessWidget {
  const _MapActionButton({
    required this.tooltip,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      tooltip: tooltip,
      heroTag: 'question-home-create',
      elevation: 8,
      backgroundColor: const Color(0xFF10D7C3),
      foregroundColor: const Color(0xFF042B30),
      onPressed: onTap,
      icon: Icon(icon),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w900)),
    );
  }
}

class _QuestionBubblePainter extends CustomPainter {
  const _QuestionBubblePainter({required this.accentColor});

  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
    const tailHeight = 12.0;
    const tailWidth = 18.0;
    const radius = 18.0;
    const inset = 1.5;
    final bubbleBottom = size.height - tailHeight - inset;
    final tailCenter = size.width / 2;

    final path = Path()
      ..moveTo(inset + radius, inset)
      ..lineTo(size.width - inset - radius, inset)
      ..quadraticBezierTo(
        size.width - inset,
        inset,
        size.width - inset,
        inset + radius,
      )
      ..lineTo(size.width - inset, bubbleBottom - radius)
      ..quadraticBezierTo(
        size.width - inset,
        bubbleBottom,
        size.width - inset - radius,
        bubbleBottom,
      )
      ..lineTo(tailCenter + tailWidth / 2, bubbleBottom)
      ..lineTo(tailCenter, size.height - inset)
      ..lineTo(tailCenter - tailWidth / 2, bubbleBottom)
      ..lineTo(inset + radius, bubbleBottom)
      ..quadraticBezierTo(inset, bubbleBottom, inset, bubbleBottom - radius)
      ..lineTo(inset, inset + radius)
      ..quadraticBezierTo(inset, inset, inset + radius, inset)
      ..close();

    canvas.drawShadow(path, const Color(0x330B2B34), 8, true);

    final fill = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fill);

    final stroke = Paint()
      ..color = accentColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(covariant _QuestionBubblePainter oldDelegate) {
    return oldDelegate.accentColor != accentColor;
  }
}
