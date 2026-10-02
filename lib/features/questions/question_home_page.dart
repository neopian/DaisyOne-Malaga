import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../../core/geo/city_catalog.g.dart';
import '../../core/services/location_service.dart';
import '../../core/utils/formatters.dart';
import '../../shared/models/question.dart';
import '../../shared/widgets/app_drawer.dart';
import '../../shared/widgets/status_chip.dart';
import '../../shared/widgets/travel_city_picker.dart';
import 'question_realtime.dart';
import 'question_repository.dart';

const _currentLocationZoom = 13.0;

class QuestionHomePage extends ConsumerStatefulWidget {
  const QuestionHomePage({super.key, this.tileProvider});

  final TileProvider? tileProvider;

  @override
  ConsumerState<QuestionHomePage> createState() => _QuestionHomePageState();
}

class _QuestionHomePageState extends ConsumerState<QuestionHomePage> {
  late final MapController _mapController;
  late final TextEditingController _searchController;
  Future<DeviceCoordinates?>? _currentLocationRequest;
  DeviceCoordinates? _pendingCameraMove;
  DeviceCoordinates? _currentCoordinates;
  LatLngBounds? _visibleBounds;
  bool _isMapReady = false;
  bool _isResolvingLocation = false;
  double _questionSheetSize = _questionSheetInitialSize;
  String _searchQuery = '';
  String? _locationError;
  int _cameraIntentRevision = 0;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _mapController.dispose();
    super.dispose();
  }

  Future<DeviceCoordinates?> _refreshCurrentLocation({
    bool moveCamera = false,
  }) {
    final cameraRevision = _cameraIntentRevision;
    final activeRequest = _currentLocationRequest;
    if (activeRequest != null) {
      return activeRequest.then((coordinates) {
        if (moveCamera &&
            coordinates != null &&
            mounted &&
            cameraRevision == _cameraIntentRevision) {
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
    final cameraRevision = _cameraIntentRevision;
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
      if (moveCamera && cameraRevision == _cameraIntentRevision) {
        _moveMapToCoordinates(coordinates);
      }
      return coordinates;
    } catch (error) {
      if (!mounted) return null;
      setState(() => _locationError = _locationMessage(error));
      return null;
    } finally {
      if (mounted) setState(() => _isResolvingLocation = false);
    }
  }

  Future<void> _moveToCurrentLocation() async {
    _cameraIntentRevision++;
    final coordinates = await _refreshCurrentLocation(moveCamera: true);
    if (!mounted || coordinates != null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_locationError ?? '현재 위치를 확인하지 못했습니다.')),
    );
  }

  Future<void> _chooseMapCity() async {
    final city = await showTravelCityPicker(context);
    if (!mounted || city == null) return;
    _cameraIntentRevision++;
    _moveMapToCoordinates(
      DeviceCoordinates(latitude: city.latitude, longitude: city.longitude),
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
      final viewportHeight = MediaQuery.sizeOf(context).height;
      final coveredHeight = viewportHeight * _questionSheetSize;
      _mapController.move(
        LatLng(coordinates.latitude, coordinates.longitude),
        _currentLocationZoom,
        offset: Offset(0, -coveredHeight / 2),
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
    ref.watch(questionRealtimeProvider);
    final questions = ref.watch(questionsProvider);
    final items = questions.asData?.value ?? const <Question>[];
    final matchingItems = _searchQuestions(items, _searchQuery);
    final visibleItems = _visibleQuestions(matchingItems);
    final isLoading =
        (questions.isLoading && !questions.hasValue) || _visibleBounds == null;

    return Scaffold(
      drawer: const AppDrawer(),
      body: Stack(
        children: [
          Positioned.fill(
            child: _MapSurface(
              mapController: _mapController,
              tileProvider: widget.tileProvider,
              questions: matchingItems,
              currentCoordinates: _currentCoordinates,
              bottomPadding:
                  MediaQuery.sizeOf(context).height * _questionSheetSize,
              onMapReady: _handleMapReady,
              onVisibleBoundsChanged: _handleVisibleBoundsChanged,
            ),
          ),
          _MapTopBar(
            searchController: _searchController,
            onSearchChanged: _handleSearchChanged,
            onClearSearch: _clearSearch,
            onSwitchRole: () => context.go('/helper/home'),
            onOpenActivity: () => context.go('/activity/traveler'),
            notices: _questionSheetSize > .55
                ? const []
                : [
                    if (_locationError != null)
                      _MapNotice(
                        message:
                            '위치를 사용할 수 없어 전체 지도를 보여드려요. 질문할 지역은 직접 선택할 수 있어요.',
                        detail: _locationError,
                        icon: Icons.location_off_outlined,
                      ),
                    if (!questions.hasError &&
                        _locationError == null &&
                        items.any(
                          (question) =>
                              question.latitude == null ||
                              question.longitude == null,
                        ))
                      const _MapNotice(message: '위치가 없는 이전 질문은 지도에 표시되지 않아요.'),
                  ],
          ),
          Positioned.fill(
            child: _QuestionSheet(
              questions: visibleItems,
              isLoading: isLoading,
              hasError: questions.hasError,
              onRetry: () => ref.invalidate(questionsProvider),
              searchQuery: _searchQuery,
              onSizeChanged: _handleQuestionSheetSizeChanged,
              onCreateQuestion: () => context.go('/questions/new'),
            ),
          ),
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Stack(
                  children: [
                    Positioned(
                      left: 18,
                      bottom: constraints.maxHeight * _questionSheetSize + 16,
                      child: _CircleMapButton(
                        tooltip: '여행할 도시 선택',
                        icon: Icons.public_rounded,
                        onTap: _chooseMapCity,
                      ),
                    ),
                    Positioned(
                      right: 18,
                      bottom: constraints.maxHeight * _questionSheetSize + 16,
                      child: _CircleMapButton(
                        tooltip: _isResolvingLocation
                            ? '현재 위치 확인 중'
                            : '현재 위치로 이동',
                        icon: _isResolvingLocation
                            ? Icons.sync_rounded
                            : Icons.my_location_rounded,
                        onTap: _moveToCurrentLocation,
                      ),
                    ),
                  ],
                );
              },
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

  void _handleSearchChanged(String value) {
    if (_searchQuery == value) return;
    setState(() => _searchQuery = value);
  }

  void _clearSearch() {
    _searchController.clear();
    _handleSearchChanged('');
  }

  void _handleVisibleBoundsChanged(String mapIdentity, LatLngBounds bounds) {
    if (mapIdentity != _mapIdentity(_currentCoordinates)) return;
    final current = _visibleBounds;
    if (current != null && _sameBounds(current, bounds)) return;
    if (!mounted) return;
    setState(() => _visibleBounds = bounds);
  }

  void _handleQuestionSheetSizeChanged(double size) {
    if ((_questionSheetSize - size).abs() < .001 || !mounted) return;
    setState(() => _questionSheetSize = size);
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
  if (coordinates == null) return 'travel-map';
  return 'travel-map-${coordinates.latitude.toStringAsFixed(4)}-${coordinates.longitude.toStringAsFixed(4)}';
}

List<Question> _searchQuestions(List<Question> questions, String query) {
  final keyword = query.trim().toLowerCase();
  if (keyword.isEmpty) return questions;

  return questions.where((question) {
    return question.country.toLowerCase().contains(keyword) ||
        question.city.toLowerCase().contains(keyword) ||
        (CityCatalog.findCity(
              question.country,
              question.city,
            )?.cityKo.contains(keyword) ??
            false) ||
        question.title.toLowerCase().contains(keyword) ||
        question.body.toLowerCase().contains(keyword) ||
        question.answers.any(
          (answer) => answer.body.toLowerCase().contains(keyword),
        ) ||
        question.comments.any(
          (comment) => comment.body.toLowerCase().contains(keyword),
        );
  }).toList();
}

_SearchSnippet? _matchingSnippet(Question question, String query) {
  final keyword = query.trim();
  if (keyword.isEmpty) return null;

  final candidates = <_SearchSnippet>[
    _SearchSnippet(label: '내용', text: question.body),
    for (final answer in question.answers)
      _SearchSnippet(label: '답변', text: answer.body),
    for (final comment in question.comments)
      _SearchSnippet(label: '코멘트', text: comment.body),
  ];
  for (final candidate in candidates) {
    final matchIndex = candidate.text.toLowerCase().indexOf(
      keyword.toLowerCase(),
    );
    if (matchIndex >= 0) {
      return _SearchSnippet(
        label: candidate.label,
        text: _excerptAroundMatch(candidate.text, matchIndex, keyword.length),
      );
    }
  }
  return null;
}

String _excerptAroundMatch(String text, int matchIndex, int matchLength) {
  const contextLength = 36;
  final start = (matchIndex - contextLength).clamp(0, text.length);
  final end = (matchIndex + matchLength + contextLength).clamp(0, text.length);
  return '${start > 0 ? '…' : ''}${text.substring(start, end)}${end < text.length ? '…' : ''}';
}

class _SearchSnippet {
  const _SearchSnippet({required this.label, required this.text});

  final String label;
  final String text;
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
    required this.searchController,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.onSwitchRole,
    required this.onOpenActivity,
    required this.notices,
  });

  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;
  final VoidCallback onSwitchRole;
  final VoidCallback onOpenActivity;
  final List<Widget> notices;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final media = MediaQuery.of(context);
    final compact = media.size.height - media.viewInsets.bottom < 600;
    final menu = IconButton(
      tooltip: '메뉴 열기',
      onPressed: () => Scaffold.of(context).openDrawer(),
      icon: const Icon(Icons.menu_rounded),
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
    );
    final search = _MapSearchField(
      controller: searchController,
      onChanged: onSearchChanged,
      onClear: onClearSearch,
      prefixAction: compact ? menu : null,
      trailingAction: compact
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '내 질문',
                  onPressed: onOpenActivity,
                  icon: const Icon(Icons.inbox_outlined),
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                ),
                IconButton(
                  tooltip: '답변자로 전환',
                  onPressed: onSwitchRole,
                  icon: const Icon(Icons.support_agent_rounded),
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                ),
              ],
            )
          : null,
    );
    return Positioned(
      left: 16,
      right: 16,
      top: media.padding.top + 12,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Material(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(24),
                elevation: 4,
                shadowColor: scheme.shadow.withValues(alpha: .10),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: compact
                      ? search
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                menu,
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    '여행 Q&A',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -.7,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: '내 질문',
                                  onPressed: onOpenActivity,
                                  icon: const Icon(Icons.inbox_outlined),
                                  constraints: const BoxConstraints(
                                    minWidth: 48,
                                    minHeight: 48,
                                  ),
                                ),
                                Tooltip(
                                  message: '답변자로 전환',
                                  child: TextButton.icon(
                                    onPressed: onSwitchRole,
                                    icon: const Icon(
                                      Icons.support_agent_rounded,
                                      size: 19,
                                    ),
                                    label: const Text('답변하기'),
                                    style: TextButton.styleFrom(
                                      minimumSize: const Size(48, 48),
                                      foregroundColor: scheme.onSurfaceVariant,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            search,
                          ],
                        ),
                ),
              ),
              for (final notice in notices)
                Padding(padding: const EdgeInsets.only(top: 8), child: notice),
            ],
          ),
        ),
      ),
    );
  }
}

class _MapSearchField extends StatelessWidget {
  const _MapSearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
    this.prefixAction,
    this.trailingAction,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final Widget? prefixAction;
  final Widget? trailingAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
      decoration: InputDecoration(
        hintText: '어떤 도움이 필요하세요?',
        labelText: '질문 검색',
        floatingLabelBehavior: FloatingLabelBehavior.never,
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        prefixIcon:
            prefixAction ??
            Icon(Icons.search_rounded, color: scheme.onSurfaceVariant),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (value.text.isNotEmpty)
                  IconButton(
                    tooltip: '검색어 지우기',
                    onPressed: onClear,
                    icon: const Icon(Icons.cancel_rounded, size: 20),
                  ),
                if (trailingAction != null) trailingAction!,
              ],
            );
          },
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 15,
        ),
      ),
      style: theme.textTheme.bodyLarge,
    );
  }
}

class _MapSurface extends StatelessWidget {
  const _MapSurface({
    required this.mapController,
    required this.questions,
    required this.currentCoordinates,
    required this.bottomPadding,
    required this.tileProvider,
    required this.onMapReady,
    required this.onVisibleBoundsChanged,
  });

  final MapController mapController;
  final List<Question> questions;
  final DeviceCoordinates? currentCoordinates;
  final double bottomPadding;
  final TileProvider? tileProvider;
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
            ? const LatLng(44.0, -35.0)
            : LatLng(currentCoordinates.latitude, currentCoordinates.longitude),
        initialZoom: currentCoordinates == null ? 2.0 : _currentLocationZoom,
        minZoom: 2,
        maxZoom: 17,
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
          tileProvider: tileProvider,
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
              markerTextScale: MediaQuery.textScalerOf(context).scale(22) / 22,
            );
            if (camera.zoom >= _questionClusterMaxZoom) {
              final locationMarker = _currentLocationMarker(currentCoordinates);
              if (locationMarker != null) markers.add(locationMarker);
            }
            return MarkerLayer(markers: markers);
          },
        ),
        Padding(
          padding: EdgeInsets.only(bottom: bottomPadding + 16, left: 12),
          child: RichAttributionWidget(
            alignment: AttributionAlignment.bottomLeft,
            attributions: [
              TextSourceAttribution('OpenStreetMap contributors', onTap: () {}),
            ],
          ),
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
  required double markerTextScale,
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
      markerTextScale: markerTextScale,
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
  required double markerTextScale,
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
    final markerSize =
        _clusterMarkerSize(bucket.count) *
        markerTextScale.clamp(1.0, double.infinity);
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
    final scheme = Theme.of(context).colorScheme;
    final color = scheme.onSurface;
    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: .94),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: .6),
          ),
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
      _LocalizedMapLabelTier.country => FontWeight.w700,
      _LocalizedMapLabelTier.region => FontWeight.w600,
      _LocalizedMapLabelTier.city => FontWeight.w600,
      _LocalizedMapLabelTier.local => FontWeight.w500,
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
}

final _localizedMapPlaces = [
  for (final city in CityCatalog.knownPlaces)
    _LocalizedMapPlace(
      latitude: city.latitude,
      longitude: city.longitude,
      tier: _LocalizedMapLabelTier.city,
      labels: {'ko': city.cityKo, 'native': city.nativeName},
    ),
];

class _QuestionClusterMarker extends StatelessWidget {
  const _QuestionClusterMarker({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final displayCount = count > 99 ? '99+' : '$count';

    return Semantics(
      label: '$count개 질문이 있는 지역 확대',
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primary,
              border: Border.all(color: scheme.surface, width: 3),
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
                    style: TextStyle(
                      color: scheme.onPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      height: 1,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '질문',
                    maxLines: 1,
                    style: TextStyle(
                      color: scheme.onPrimary,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      height: 1,
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

class _QuestionPin extends StatelessWidget {
  const _QuestionPin({required this.question});

  final Question question;

  @override
  Widget build(BuildContext context) {
    final style = _QuestionCategoryStyle.forCategory(question.category);

    return Tooltip(
      message: question.title,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => context.go('/questions/${question.id}'),
          child: CustomPaint(
            painter: _QuestionBubblePainter(
              accentColor: Theme.of(context).colorScheme.primary,
              surfaceColor: Theme.of(context).colorScheme.surface,
            ),
            child: SizedBox(
              width: 104,
              height: 56,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 7, 12, 18),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      style.icon,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        formatPoints(question.rewardPoints),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QuestionCategoryStyle {
  const _QuestionCategoryStyle({required this.icon});

  final IconData icon;

  static _QuestionCategoryStyle forCategory(String category) {
    return _QuestionCategoryStyle(
      icon: switch (category) {
        '교통' => Icons.directions_bus_filled_outlined,
        '번역' => Icons.translate,
        '생활' => Icons.home_repair_service_outlined,
        '쇼핑' => Icons.shopping_bag_outlined,
        '식당' => Icons.restaurant_menu,
        '긴급도움' => Icons.sos_outlined,
        _ => Icons.help_outline,
      },
    );
  }
}

class _CurrentLocationMarker extends StatelessWidget {
  const _CurrentLocationMarker();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '현재 위치',
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: .16),
              shape: BoxShape.circle,
              border: Border.all(
                color: scheme.primary.withValues(alpha: .25),
                width: 1.5,
              ),
            ),
          ),
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: scheme.primary,
              shape: BoxShape.circle,
              border: Border.all(color: scheme.surface, width: 4),
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: .18),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

const _questionSheetInitialSize = .34;
const _questionSheetMinSize = .20;
const _questionSheetMaxSize = .68;

class _QuestionSheet extends StatefulWidget {
  const _QuestionSheet({
    required this.questions,
    required this.isLoading,
    required this.hasError,
    required this.onRetry,
    required this.searchQuery,
    required this.onSizeChanged,
    required this.onCreateQuestion,
  });

  final List<Question> questions;
  final bool isLoading;
  final bool hasError;
  final VoidCallback onRetry;
  final String searchQuery;
  final ValueChanged<double> onSizeChanged;
  final VoidCallback onCreateQuestion;

  @override
  State<_QuestionSheet> createState() => _QuestionSheetState();
}

class _QuestionSheetState extends State<_QuestionSheet> {
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  @override
  void initState() {
    super.initState();
    _sheetController.addListener(_notifySizeChanged);
  }

  @override
  void dispose() {
    _sheetController.removeListener(_notifySizeChanged);
    _sheetController.dispose();
    super.dispose();
  }

  void _notifySizeChanged() {
    widget.onSizeChanged(_sheetController.size);
  }

  void _handleDragUpdate(DragUpdateDetails details, double availableHeight) {
    if (!_sheetController.isAttached || availableHeight <= 0) return;

    final dragDelta = details.primaryDelta ?? 0;
    final nextSize = (_sheetController.size - dragDelta / availableHeight)
        .clamp(_questionSheetMinSize, _questionSheetMaxSize)
        .toDouble();
    _sheetController.jumpTo(nextSize);
  }

  void _toggleExpanded() {
    if (!_sheetController.isAttached) return;
    final target = _sheetController.size > .45
        ? _questionSheetInitialSize
        : _questionSheetMaxSize;
    _sheetController.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        return DraggableScrollableSheet(
          controller: _sheetController,
          initialChildSize: _questionSheetInitialSize,
          minChildSize: _questionSheetMinSize,
          maxChildSize: _questionSheetMaxSize,
          builder: (context, controller) {
            final header = Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 16, 16),
              child: _SheetHeader(
                count: widget.questions.length,
                searchQuery: widget.searchQuery,
                isLoading: widget.isLoading,
                hasError: widget.hasError,
                onCreateQuestion: widget.onCreateQuestion,
              ),
            );
            final handle = _QuestionSheetDragHandle(
              onTap: _toggleExpanded,
              onDragUpdate: (details) {
                _handleDragUpdate(details, constraints.maxHeight);
              },
            );
            final items = <Widget>[
              if (widget.isLoading)
                const _SheetLoading()
              else if (widget.hasError)
                _QuestionFeedError(onRetry: widget.onRetry)
              else if (widget.questions.isEmpty)
                _EmptyMapState(searchQuery: widget.searchQuery)
              else
                for (final question in widget.questions)
                  _NearbyQuestionTile(
                    question: question,
                    searchQuery: widget.searchQuery,
                  ),
            ];
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Material(
                  color: scheme.surface,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(28),
                  ),
                  clipBehavior: Clip.antiAlias,
                  elevation: 8,
                  shadowColor: scheme.shadow.withValues(alpha: .10),
                  child: LayoutBuilder(
                    builder: (context, sheetConstraints) {
                      // A scrollable header keeps all actions reachable when the
                      // keyboard or a landscape viewport leaves little height.
                      if (sheetConstraints.maxHeight < 170 ||
                          MediaQuery.textScalerOf(context).scale(16) > 22) {
                        return ListView(
                          controller: controller,
                          padding: EdgeInsets.only(
                            bottom: MediaQuery.paddingOf(context).bottom + 20,
                          ),
                          children: [
                            handle,
                            header,
                            for (final item in items)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                child: item,
                              ),
                          ],
                        );
                      }
                      return Column(
                        children: [
                          handle,
                          header,
                          Divider(
                            height: 1,
                            color: scheme.outlineVariant.withValues(alpha: .55),
                          ),
                          Expanded(
                            child: ListView(
                              controller: controller,
                              padding: EdgeInsets.fromLTRB(
                                16,
                                12,
                                16,
                                MediaQuery.paddingOf(context).bottom + 20,
                              ),
                              children: items,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _QuestionSheetDragHandle extends StatelessWidget {
  const _QuestionSheetDragHandle({
    required this.onDragUpdate,
    required this.onTap,
  });

  final GestureDragUpdateCallback onDragUpdate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '질문 목록 펼치기 또는 접기',
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: onDragUpdate,
        child: Tooltip(
          message: '질문 목록 펼치기 또는 접기',
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: Center(
                child: Container(
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant.withValues(alpha: .3),
                    borderRadius: BorderRadius.circular(3),
                  ),
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
  const _SheetHeader({
    required this.count,
    required this.searchQuery,
    required this.isLoading,
    required this.hasError,
    required this.onCreateQuestion,
  });

  final int count;
  final String searchQuery;
  final bool isLoading;
  final bool hasError;
  final VoidCallback onCreateQuestion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          searchQuery.trim().isEmpty ? '이 지역의 질문' : '검색 결과',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -.5,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          isLoading
              ? '주변 질문을 살펴보는 중'
              : hasError
              ? '연결 후 다시 확인해주세요'
              : '현재 지도에서 $count개',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    final action = FilledButton.icon(
      onPressed: onCreateQuestion,
      icon: const Icon(Icons.add_rounded, size: 20),
      label: const Text('질문하기'),
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 440 &&
            MediaQuery.textScalerOf(context).scale(16) > 20) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [action, const SizedBox(height: 12), heading],
          );
        }
        return Row(
          children: [
            Expanded(child: heading),
            const SizedBox(width: 12),
            action,
          ],
        );
      },
    );
  }
}

class _QuestionFeedError extends StatelessWidget {
  const _QuestionFeedError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('질문을 불러오지 못했어요', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text('현재 목록을 확인할 수 없어요. 연결 후 다시 불러와주세요.'),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('질문 다시 불러오기'),
          ),
        ],
      ),
    ),
  );
}

class _NearbyQuestionTile extends StatelessWidget {
  const _NearbyQuestionTile({required this.question, this.searchQuery = ''});

  final Question question;
  final String searchQuery;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final category = _QuestionCategoryStyle.forCategory(question.category);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => context.go('/questions/${question.id}'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        category.icon,
                        size: 20,
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _HighlightedText(
                        text: question.title,
                        query: searchQuery,
                        maxLines: 2,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                          letterSpacing: -.2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    StatusChip(
                      label: question.status,
                      emphasis: question.isOpen,
                      compact: true,
                    ),
                    StatusChip(label: question.urgency, compact: true),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        formatPoints(question.rewardPoints),
                        semanticsLabel:
                            '질문 보상 ${formatPoints(question.rewardPoints)}',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  '${question.locationLabel} · ${formatDate(question.createdAt)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                if (_matchingSnippet(question, searchQuery)
                    case final snippet?) ...[
                  const SizedBox(height: 10),
                  _HighlightedText(
                    text: '${snippet.label} · ${snippet.text}',
                    query: searchQuery,
                    maxLines: 2,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HighlightedText extends StatelessWidget {
  const _HighlightedText({
    required this.text,
    required this.query,
    required this.maxLines,
    this.style,
  });

  final String text;
  final String query;
  final int maxLines;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final keyword = query.trim();
    if (keyword.isEmpty) {
      return Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }

    final matches = RegExp(
      RegExp.escape(keyword),
      caseSensitive: false,
    ).allMatches(text).toList();
    if (matches.isEmpty) {
      return Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }

    final spans = <TextSpan>[];
    var cursor = 0;
    for (final match in matches) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      spans.add(
        TextSpan(
          text: text.substring(match.start, match.end),
          style: TextStyle(
            color: Theme.of(context).colorScheme.onPrimaryContainer,
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }

    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _MapNotice extends StatelessWidget {
  const _MapNotice({
    required this.message,
    this.detail,
    this.icon = Icons.info_outline_rounded,
  });

  final String message;
  final String? detail;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = Material(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(18),
      elevation: 2,
      shadowColor: theme.colorScheme.shadow.withValues(alpha: .06),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return detail == null ? content : Tooltip(message: detail!, child: content);
  }
}

class _SheetLoading extends StatelessWidget {
  const _SheetLoading();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            semanticsLabel: '주변 질문 불러오는 중',
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

class _EmptyMapState extends StatelessWidget {
  const _EmptyMapState({required this.searchQuery});

  final String searchQuery;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Column(
        children: [
          Icon(
            Icons.explore_outlined,
            size: 32,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            searchQuery.trim().isEmpty ? '아직 이 지역의 질문이 없어요' : '일치하는 질문이 없어요',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            searchQuery.trim().isEmpty
                ? '지도를 움직여 둘러보거나, 궁금한 것을 먼저 물어보세요.'
                : '검색어를 바꾸거나 다른 지역을 살펴보세요.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
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
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(16),
      elevation: 3,
      shadowColor: scheme.shadow.withValues(alpha: .10),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        color: scheme.primary,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        icon: Icon(icon, size: 22),
      ),
    );
  }
}

class _QuestionBubblePainter extends CustomPainter {
  const _QuestionBubblePainter({
    required this.accentColor,
    required this.surfaceColor,
  });

  final Color accentColor;
  final Color surfaceColor;

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
      ..color = surfaceColor
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fill);

    final stroke = Paint()
      ..color = accentColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(covariant _QuestionBubblePainter oldDelegate) {
    return oldDelegate.accentColor != accentColor ||
        oldDelegate.surfaceColor != surfaceColor;
  }
}
