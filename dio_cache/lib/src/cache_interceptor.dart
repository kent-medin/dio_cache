import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio_cache/src/cache_response.dart';
import 'package:dio_cache/src/stores/memory_cache_store.dart';
import 'package:logging/logging.dart';

import 'options.dart';
import 'result.dart';
import 'helpers/status_code.dart';
import 'stores/cache_store.dart';

class CacheInterceptor extends Interceptor {
  final CacheOptions options;
  final Logger logger;
  final CacheStore _globalStore;

  CacheInterceptor({CacheOptions options, this.logger})
      : this.options = options ?? const CacheOptions(),
        this._globalStore = options?.store ?? MemoryCacheStore();

  CacheOptions _optionsForRequest(RequestOptions options) {
    return CacheOptions.fromExtra(options) ?? this.options;
  }

  @override
  onRequest(RequestOptions options) async {
    final extraOptions = _optionsForRequest(options);

    if (!extraOptions.isCached) {
      return await super.onRequest(options);
    }

    final cacheKey = extraOptions.keyBuilder(options);
    assert(cacheKey != null, "The cache key builder produced an empty key");
    final store = extraOptions.store ?? _globalStore;
    final existing = await store.get(cacheKey);

    existing?.updateRequest(options, !extraOptions.forceUpdate);

    if (extraOptions.forceUpdate) {
      logger
          ?.fine("[$cacheKey][${options.uri}] Update forced, cache is ignored");
      return await super.onRequest(options);
    }

    if (existing == null) {
      logger?.fine(
          "[$cacheKey][${options.uri}] No existing cache, starting a new request");
      return await super.onRequest(options);
    }

    if (!extraOptions.forceCache && existing.expiry.isBefore(DateTime.now())) {
      logger?.fine(
          "[$cacheKey][${options.uri}] Cache expired since ${existing.expiry}, starting a new request");
      return await super.onRequest(options);
    }

    logger?.fine("[$cacheKey][${options.uri}] Using existing response from ${existing.downloadedAt} expires at ${existing.expiry}");
    return existing.toResponse(options);
  }

  @override
  onError(DioError err) async {
    final extraOptions = _optionsForRequest(err.request);
    if (extraOptions.returnCacheOnError) {
      final existing = CacheResponse.fromError(err);
      if (existing != null) {
        final cacheKey = extraOptions.keyBuilder(err.request);
        logger?.warning(
            "[$cacheKey][${err.request.uri}] An error occured, but using an existing cache : ${err.error}");
        return existing;
      }
    }

    return super.onError(err);
  }

  @override
  onResponse(Response response) async {
    final requestExtra = _optionsForRequest(response.request);
    final extras = CacheResult.fromExtra(response);
    final store = requestExtra.store ?? _globalStore;

    // If response is not extracted from cache we save it into the store
    if (!extras.isFromCache && requestExtra.isCached) {
      final cacheControlDirectives = parseCacheControl(response.headers['cache-control']);
      final int maxAge = parseInt(cacheControlDirectives['max-age']);


      // TODO check for other cache-control directives (e.g. no-cache)
      if (maxAge == 0) {
        logger?.fine('[${response.request.uri}] Not caching response because server wants it uncached');
        return await super.onResponse(response);
      }

      final cacheKey = requestExtra.keyBuilder(response.request);
      final expiryDateTime = DateTime.now().add(Duration(seconds: maxAge) ?? requestExtra.expiry);

      if (response.statusCode == HttpStatus.notModified) {
        final existing = CacheResponse.fromRequestOptions(response.request);
        await store.updateExpiry(cacheKey, expiryDateTime);

        logger?.fine("[$cacheKey][${response.request.uri}] Not modified.  Using existing response from ${existing.downloadedAt} now expires at ${existing.expiry}");
        return existing.toResponse(response.request);
      }

      if (isValidHttpStatusCode(response.statusCode)) {
        final newCache = await CacheResponse.fromResponse(
            cacheKey, response, expiryDateTime, requestExtra.priority);
        logger?.fine(
            "[$cacheKey][${response.request.uri}] Creating a new cache entry that expires on $expiryDateTime");
        await store.set(newCache);
      }
    }

    return await super.onResponse(response);
  }

Map<String, String> parseCacheControl(List<String> cacheControl) {
  if (cacheControl == null) {
    return {};
  }

  Map<String, String> cacheControlEntries = {};
  cacheControl.forEach((cc) {
    cc.split(',').forEach((e) {
      var parts = e.split('=');
      var left = stripQuotes(parts[0].trim());
      var right = stripQuotes(parts.length == 1 ? null : parts[1].trim());
      cacheControlEntries[left] = right;
    });
  });

  return cacheControlEntries;
}

String stripQuotes(String s) {
  if (s == null) {
    return null;
  }
  
  if (s[0] == '\'' || s[0] == '"') {
    return s.substring(1, s.length - 1);
  }
  
  return s;
}

int parseInt(String s) {
  return s == null ? null : int.tryParse(s);
  
}
}
