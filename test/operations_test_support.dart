import 'package:local_qa_concierge/core/geo/city_catalog.g.dart';
import 'package:local_qa_concierge/features/admin/operations_repository.dart';
import 'package:local_qa_concierge/features/auth/auth_repository.dart';
import 'package:local_qa_concierge/shared/models/app_user.dart';

AppUser operationsUser({
  String id = 'admin',
  bool isAdmin = true,
  bool isSuspended = false,
}) => AppUser(
  id: id,
  email: '$id@example.test',
  name: '관리자',
  pointBalance: 0,
  isAdmin: isAdmin,
  isSuspended: isSuspended,
);

class OperationsTestAuth extends AuthRepository {
  OperationsTestAuth(super.client);
  AppUser? user = operationsUser();
  @override
  AppUser? get currentUser => user;
  void change(AppUser? next) {
    user = next;
    notifyListeners();
  }
}

const operationsSummary = OperationsSummary(
  openCount: 42,
  assignedCount: 8,
  answeredCount: 3,
);

Map<String, dynamic> operationsRow(
  String id, {
  OperationsStatus status = OperationsStatus.open,
  String country = 'France',
  String city = 'Paris',
  bool restricted = false,
}) => {
  'id': id,
  'title': '질문 $id',
  'country': country,
  'city': city,
  'status': status.name,
  'created_at': '2026-09-28T01:00:00.000000Z',
  'updated_at': '2026-10-02T03:00:00.000000Z',
  'operational_flags': {
    'question_hidden': restricted,
    'traveler_suspended': restricted,
    'guide_suspended': restricted,
    'guide_application_restricted': restricted,
    'participants_blocked': restricted,
  },
};

OperationsQuestion operationsQuestion(
  String id, {
  OperationsStatus status = OperationsStatus.open,
  String country = 'France',
  String city = 'Paris',
  bool restricted = false,
}) => OperationsQuestion.fromMap(
  operationsRow(
    id,
    status: status,
    country: country,
    city: city,
    restricted: restricted,
  ),
);

class OperationsTestRepository extends OperationsRepository {
  OperationsTestRepository(super.client);
  final calls =
      <({OperationsStatus status, TravelCity? city, String? cursor})>[];
  Future<OperationsPageData> Function(OperationsStatus, TravelCity?, String?)
  response = (_, _, _) async =>
      const OperationsPageData(items: [], summary: operationsSummary);

  @override
  Future<OperationsPageData> fetchPage({
    required OperationsStatus status,
    TravelCity? city,
    String? cursor,
  }) {
    calls.add((status: status, city: city, cursor: cursor));
    return response(status, city, cursor);
  }
}
