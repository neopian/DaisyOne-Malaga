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
  DeviceCoordinates? _currentCoordinates;
  LatLngBounds? _visibleBounds;
  bool _isResolvingLocation = false;
  String? _locationError;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshCurrentLocation();
    });
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  Future<DeviceCoordinates?> _refreshCurrentLocation() async {
    if (_isResolvingLocation) return _currentCoordinates;
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
    final coordinates = _currentCoordinates ?? await _refreshCurrentLocation();
    if (!mounted || coordinates == null) return;
    setState(() => _locationError = null);
    _mapController.move(
      LatLng(coordinates.latitude, coordinates.longitude),
      _currentLocationZoom,
    );
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
          _QuestionSheet(
            questions: visibleItems,
            profile: profile,
            isLoading: isLoading,
          ),
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
    required this.onVisibleBoundsChanged,
  });

  final MapController mapController;
  final List<Question> questions;
  final DeviceCoordinates? currentCoordinates;
  final _VisibleBoundsChanged onVisibleBoundsChanged;

  @override
  Widget build(BuildContext context) {
    final currentCoordinates = this.currentCoordinates;
    final mapIdentity = _mapIdentity(currentCoordinates);
    final markers = questions
        .where(
          (question) => question.latitude != null && question.longitude != null,
        )
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
    if (currentCoordinates != null) {
      markers.add(
        Marker(
          point: LatLng(
            currentCoordinates.latitude,
            currentCoordinates.longitude,
          ),
          width: 70,
          height: 70,
          alignment: Alignment.center,
          child: const _CurrentLocationMarker(),
        ),
      );
    }

    return FlutterMap(
      key: ValueKey(mapIdentity),
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
          onVisibleBoundsChanged(
            mapIdentity,
            mapController.camera.visibleBounds,
          );
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
        MarkerLayer(markers: markers),
        RichAttributionWidget(
          attributions: [
            TextSourceAttribution('OpenStreetMap contributors', onTap: () {}),
          ],
        ),
      ],
    );
  }
}

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

class _QuestionSheet extends StatelessWidget {
  const _QuestionSheet({
    required this.questions,
    required this.profile,
    required this.isLoading,
  });

  final List<Question> questions;
  final AppUser? profile;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: .28,
      minChildSize: .20,
      maxChildSize: .68,
      snap: true,
      snapSizes: const [.28, .68],
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
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD8E2DF),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              _SheetHeader(profile: profile, count: questions.length),
              const SizedBox(height: 14),
              if (isLoading)
                const _SheetLoading()
              else if (questions.isEmpty)
                const _EmptyMapState()
              else
                for (final question in questions)
                  _NearbyQuestionTile(question: question),
            ],
          ),
        );
      },
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.profile, required this.count});

  final AppUser? profile;
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
          profile == null
              ? '현재 화면 · $count개 질문'
              : '현재 화면 · 잔액 ${formatPoints(profile!.pointBalance)} · $count개 질문',
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
