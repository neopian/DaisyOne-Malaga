import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/services/api_service.dart';
import '../../shared/models/question.dart';
import '../auth/auth_repository.dart';

final questionRepositoryProvider = Provider<QuestionRepository>(
  (ref) => QuestionRepository(ref.watch(apiClientProvider)),
);
final questionsProvider = FutureProvider<List<Question>>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(questionRepositoryProvider).fetchVisibleQuestions();
});
final helperOpenQuestionsProvider = FutureProvider<List<Question>>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(questionRepositoryProvider).fetchOpenQuestions();
});
final questionProvider = FutureProvider.family<Question, String>((ref, id) {
  ref.watch(authStateProvider);
  return ref.watch(questionRepositoryProvider).fetchQuestion(id);
});

class QuestionRepository {
  const QuestionRepository(this._client);
  final ApiClient _client;
  static const maxImages = 5;
  static const maxImageBytes = 3 * 1024 * 1024;

  Question _question(Map<String, dynamic> row) {
    final imageRows = row['question_images'] as List? ?? [];
    return Question.fromMap({
      ...row,
      'question_images': imageRows.map((image) {
        final data = ApiClient.asMap(image);
        final url = data['image_url'] as String?;
        return {
          ...data,
          if (url != null) 'image_url': _client.resolveMediaUrl(url),
        };
      }).toList(),
    });
  }

  Future<List<Question>> fetchVisibleQuestions() async =>
      (await _client.getList('questions')).map(_question).toList();

  Future<List<Question>> fetchOpenQuestions() async =>
      (await _client.getList('guide/questions')).map(_question).toList();

  Future<Question> fetchQuestion(String questionId) async => _question(
    await _client.getMap('questions/${Uri.encodeComponent(questionId)}'),
  );

  Future<String> createQuestion({
    required String title,
    required String body,
    required String country,
    required String city,
    required String? regionName,
    required String category,
    required String urgency,
    required int rewardPoints,
    required double latitude,
    required double longitude,
    required List<XFile> images,
    String? requestId,
  }) async {
    // Image loading is asynchronous: bind the draft to its originating session
    // before the first await, rather than whichever account is active later.
    final originToken = _client.token;
    final originUserId = _client.userId;
    if (originToken == null) {
      throw const ApiException(
        '로그인이 필요합니다.',
        code: 'unauthorized',
        status: 401,
      );
    }
    if (images.length > maxImages) {
      throw const ApiException(
        '사진은 최대 5장까지 첨부할 수 있습니다.',
        code: 'invalid_image',
      );
    }
    final encodedImages = <Map<String, dynamic>>[];
    for (final image in images) {
      if (await image.length() > maxImageBytes) {
        throw const ApiException(
          '사진 한 장의 크기는 3MB 이하여야 합니다.',
          code: 'invalid_image',
        );
      }
      final bytes = await image.readAsBytes();
      if (bytes.length > maxImageBytes) {
        throw const ApiException(
          '사진 한 장의 크기는 3MB 이하여야 합니다.',
          code: 'invalid_image',
        );
      }
      final extension = image.name.split('.').last.toLowerCase();
      final mime =
          image.mimeType ??
          switch (extension) {
            'jpg' || 'jpeg' => 'image/jpeg',
            'png' => 'image/png',
            'webp' => 'image/webp',
            _ => '',
          };
      if (!const ['image/jpeg', 'image/png', 'image/webp'].contains(mime)) {
        throw const ApiException(
          'JPG, PNG 또는 WebP 사진을 첨부해주세요.',
          code: 'invalid_image',
        );
      }
      encodedImages.add({
        'name': image.name,
        'content_type': mime,
        'data_base64': base64Encode(bytes),
      });
    }
    if (_client.token != originToken || _client.userId != originUserId) {
      throw const ApiException(
        '로그인 정보가 변경되었습니다. 다시 시도해주세요.',
        code: 'session_changed',
      );
    }
    // The API stores all images and the point hold in one database transaction.
    final row = ApiClient.asMap(
      await _client.mutate(
        'questions',
        idempotencyKey: requestId,
        body: {
          'country': country,
          'city': city,
          'region_name': regionName,
          'category': category,
          'urgency': urgency,
          'title': title,
          'body': body,
          'reward_points': rewardPoints,
          'latitude': latitude,
          'longitude': longitude,
          'images': encodedImages,
        },
      ),
    );
    return row['id'] as String;
  }

  Future<void> acceptQuestion(String questionId) async {
    await _client.mutate('questions/${Uri.encodeComponent(questionId)}/accept');
  }

  Future<void> cancelQuestion(String questionId) async {
    await _client.mutate('questions/${Uri.encodeComponent(questionId)}/cancel');
  }

  Future<void> addComment({
    required String questionId,
    required String body,
  }) async {
    await _client.mutate(
      'questions/${Uri.encodeComponent(questionId)}/comments',
      body: {'body': body.trim()},
    );
  }
}
