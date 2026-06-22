module;
#include "waywallen/query/remote_query.moc.h"
#undef assert
#include <rstd/macro.hpp>
#include <QtCore/QVariant>

module waywallen;
import :query.remote;
import :app;

using namespace Qt::Literals::StringLiterals;

namespace proto = waywallen::control::v1;
using namespace qextra::prelude;

namespace waywallen
{

RemoteAvailabilityQuery::RemoteAvailabilityQuery(QObject* parent): Query(parent) {}

auto RemoteAvailabilityQuery::sources() const -> const QVariantList& { return m_sources; }
auto RemoteAvailabilityQuery::defaultSourceId() const -> const QString& {
    return m_default_source_id;
}

void RemoteAvailabilityQuery::reload() {
    setStatus(Status::Querying);
    auto backend = App::instance()->backend();

    auto req = proto::Request {};
    req.setRemoteAvailability(proto::RemoteAvailabilityRequest {});

    auto self = QWatcher { this };
    spawn([self, backend, req = std::move(req)]() mutable -> task<void> {
        auto result = co_await backend->send(std::move(req));
        co_await asio::post(asio::bind_executor(QAsyncResult::get_executor(), use_task));
        if (! self) co_return;

        self->inspect_set(result, [self](const proto::Response& rsp) {
            const auto&  av = rsp.remoteAvailability();
            QVariantList sources;
            sources.reserve(av.sources().size());
            for (const auto& src : av.sources()) {
                QVariantList sorts;
                sorts.reserve(src.sorts().size());
                for (const auto& sort : src.sorts()) {
                    QVariantMap sm;
                    sm[u"key"_s]   = sort.key();
                    sm[u"label"_s] = sort.label();
                    sorts.push_back(sm);
                }
                QStringList tags;
                for (const auto& tag : src.tags()) tags.push_back(tag);
                QVariantMap m;
                m[u"id"_s]             = src.id_proto();
                m[u"name"_s]           = src.name();
                m[u"supportsSearch"_s] = src.supportsSearch();
                m[u"sorts"_s]          = sorts;
                m[u"tags"_s]           = tags;
                m[u"contentDir"_s]     = src.contentDir();
                sources.push_back(m);
            }
            self->m_sources           = std::move(sources);
            self->m_default_source_id = av.defaultSourceId();
            Q_EMIT self->sourcesChanged();
        });
        co_return;
    });
}

RemoteSearchQuery::RemoteSearchQuery(QObject* parent)
    : Query(parent), m_model(new model::RemoteListModel(this)) {
    connect_requet_reload(&RemoteSearchQuery::sourceIdChanged, this);
    connect_requet_reload(&RemoteSearchQuery::queryChanged, this);
    connect_requet_reload(&RemoteSearchQuery::sortKeyChanged, this);
    connect_requet_reload(&RemoteSearchQuery::tagsChanged, this);
}

auto RemoteSearchQuery::sourceId() const -> const QString& { return m_source_id; }
void RemoteSearchQuery::setSourceId(const QString& v) {
    if (m_source_id != v) {
        m_source_id = v;
        Q_EMIT sourceIdChanged();
    }
}

auto RemoteSearchQuery::query() const -> const QString& { return m_query; }
void RemoteSearchQuery::setQuery(const QString& v) {
    if (m_query != v) {
        m_query = v;
        Q_EMIT queryChanged();
    }
}

auto RemoteSearchQuery::sortKey() const -> const QString& { return m_sort_key; }
void RemoteSearchQuery::setSortKey(const QString& v) {
    if (m_sort_key != v) {
        m_sort_key = v;
        Q_EMIT sortKeyChanged();
    }
}

auto RemoteSearchQuery::tags() const -> const QStringList& { return m_tags; }
void RemoteSearchQuery::setTags(const QStringList& v) {
    if (m_tags != v) {
        m_tags = v;
        Q_EMIT tagsChanged();
    }
}

auto RemoteSearchQuery::model() const -> model::RemoteListModel* { return m_model; }
auto RemoteSearchQuery::hasMore() const -> bool { return m_has_more; }
auto RemoteSearchQuery::errorText() const -> const QString& { return m_error; }

void RemoteSearchQuery::reload() {
    m_page = 1;
    fetchPage(1, false);
}

void RemoteSearchQuery::loadMore() {
    if (! m_has_more || querying()) return;
    fetchPage(m_page + 1, true);
}

void RemoteSearchQuery::fetchPage(quint32 page, bool append) {
    setStatus(Status::Querying);
    auto backend = App::instance()->backend();

    auto req   = proto::Request {};
    auto inner = proto::RemoteSearchRequest {};
    inner.setSourceId(m_source_id);
    inner.setQuery(m_query);
    inner.setSortKey(m_sort_key);
    inner.setPage(page);
    inner.setRequiredTags(m_tags);
    req.setRemoteSearch(std::move(inner));

    auto self = QWatcher { this };
    spawn([self, backend, req = std::move(req), page, append]() mutable -> task<void> {
        auto result = co_await backend->send(std::move(req));
        co_await asio::post(asio::bind_executor(QAsyncResult::get_executor(), use_task));
        if (! self) co_return;

        self->inspect_set(result, [self, page, append](const proto::Response& rsp) {
            const auto&             sr = rsp.remoteSearch();
            QList<model::RemoteRow> rows;
            rows.reserve(sr.items().size());
            for (const auto& it : sr.items()) {
                rows.push_back(model::RemoteRow {
                    it.sourceId(),
                    it.id_proto(),
                    it.title(),
                    it.previewUrl(),
                    it.author(),
                    it.installed(),
                });
            }
            if (append)
                self->m_model->append(rows);
            else
                self->m_model->reset(std::move(rows));
            self->m_page     = page;
            self->m_has_more = sr.hasMore();
            self->m_error    = sr.error();
            Q_EMIT self->stateChanged();
        });
        co_return;
    });
}

RemoteDetailsQuery::RemoteDetailsQuery(QObject* parent): Query(parent) {
    connect_requet_reload(&RemoteDetailsQuery::sourceIdChanged, this);
    connect_requet_reload(&RemoteDetailsQuery::itemIdChanged, this);
}

auto RemoteDetailsQuery::sourceId() const -> const QString& { return m_source_id; }
void RemoteDetailsQuery::setSourceId(const QString& v) {
    if (m_source_id != v) {
        m_source_id = v;
        Q_EMIT sourceIdChanged();
    }
}

auto RemoteDetailsQuery::itemId() const -> const QString& { return m_item_id; }
void RemoteDetailsQuery::setItemId(const QString& v) {
    if (m_item_id != v) {
        m_item_id = v;
        Q_EMIT itemIdChanged();
    }
}
auto RemoteDetailsQuery::description() const -> const QString& { return m_description; }
auto RemoteDetailsQuery::size() const -> const QString& { return m_size; }
auto RemoteDetailsQuery::tags() const -> const QStringList& { return m_tags; }

void RemoteDetailsQuery::reload() {
    m_description.clear();
    m_size.clear();
    m_tags.clear();
    Q_EMIT loaded();
    if (m_item_id.isEmpty()) return;
    setStatus(Status::Querying);
    auto backend = App::instance()->backend();

    auto req   = proto::Request {};
    auto inner = proto::RemoteDetailsRequest {};
    inner.setSourceId(m_source_id);
    inner.setId_proto(m_item_id);
    req.setRemoteDetails(std::move(inner));

    auto self = QWatcher { this };
    spawn([self, backend, req = std::move(req)]() mutable -> task<void> {
        auto result = co_await backend->send(std::move(req));
        co_await asio::post(asio::bind_executor(QAsyncResult::get_executor(), use_task));
        if (! self) co_return;

        self->inspect_set(result, [self](const proto::Response& rsp) {
            const auto& dr      = rsp.remoteDetails();
            self->m_description = dr.description();
            self->m_size        = dr.size();
            self->m_tags.clear();
            for (const auto& t : dr.tags()) self->m_tags.push_back(t);
            Q_EMIT self->loaded();
        });
        co_return;
    });
}

RemoteDownloadQuery::RemoteDownloadQuery(QObject* parent): Query(parent) {}

void RemoteDownloadQuery::reload() {}

void RemoteDownloadQuery::start(const QString& sourceId, const QString& id) {
    if (sourceId.isEmpty() || id.isEmpty()) return;
    setStatus(Status::Querying);
    auto backend = App::instance()->backend();

    auto req   = proto::Request {};
    auto inner = proto::RemoteDownloadRequest {};
    inner.setSourceId(sourceId);
    inner.setId_proto(id);
    req.setRemoteDownload(std::move(inner));

    auto self = QWatcher { this };
    spawn([self, backend, req = std::move(req), sourceId, id]() mutable -> task<void> {
        auto result = co_await backend->send(std::move(req));
        co_await asio::post(asio::bind_executor(QAsyncResult::get_executor(), use_task));
        if (! self) co_return;

        self->inspect_set(result, [self, sourceId, id](const proto::Response& rsp) {
            const auto& dr = rsp.remoteDownload();
            if (dr.accepted()) {
                Q_EMIT self->accepted(sourceId, id);
            } else {
                Q_EMIT self->rejected(sourceId, id, dr.error());
            }
        });
        co_return;
    });
}

void RemoteDownloadQuery::uninstall(const QString& sourceId, const QString& id) {
    if (sourceId.isEmpty() || id.isEmpty()) return;
    setStatus(Status::Querying);
    auto backend = App::instance()->backend();

    auto req   = proto::Request {};
    auto inner = proto::RemoteUninstallRequest {};
    inner.setSourceId(sourceId);
    inner.setId_proto(id);
    req.setRemoteUninstall(std::move(inner));

    auto self = QWatcher { this };
    spawn([self, backend, req = std::move(req), sourceId, id]() mutable -> task<void> {
        auto result = co_await backend->send(std::move(req));
        co_await asio::post(asio::bind_executor(QAsyncResult::get_executor(), use_task));
        if (! self) co_return;

        self->inspect_set(result, [self, sourceId, id](const proto::Response& rsp) {
            const auto& ur = rsp.remoteUninstall();
            if (ur.removed()) {
                Q_EMIT self->uninstalled(sourceId, id);
            } else {
                Q_EMIT self->uninstallFailed(sourceId, id, ur.error());
            }
        });
        co_return;
    });
}

} // namespace waywallen

#include "waywallen/query/remote_query.moc.cpp"
