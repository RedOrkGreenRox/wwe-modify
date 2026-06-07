module;
#include "waywallen/query/remote_query.moc.h"
#undef assert
#include <rstd/macro.hpp>

module waywallen;
import :query.remote;
import :app;

using namespace Qt::Literals::StringLiterals;

namespace proto = waywallen::control::v1;
using namespace qextra::prelude;

namespace waywallen
{

RemoteAvailabilityQuery::RemoteAvailabilityQuery(QObject* parent): Query(parent) {}

auto RemoteAvailabilityQuery::owned() const -> bool { return m_owned; }
auto RemoteAvailabilityQuery::contentDir() const -> const QString& { return m_content_dir; }

void RemoteAvailabilityQuery::reload() {
    setStatus(Status::Querying);
    auto backend = App::instance()->backend();

    auto req = proto::Request {};
    req.setRemoteAvailability(proto::RemoteAvailabilityRequest {});

    auto self = QWatcher { this };
    spawn([self, backend, req = std::move(req)]() mutable -> task<void> {
        auto result = co_await backend->send(std::move(req));
        co_await asio::post(asio::bind_executor(self->get_executor(), use_task));
        if (! self) co_return;

        self->inspect_set(result, [self](const proto::Response& rsp) {
            const auto& av      = rsp.remoteAvailability();
            self->m_owned       = av.owned();
            self->m_content_dir = av.contentDir();
            Q_EMIT self->ownedChanged();
        });
        co_return;
    });
}

RemoteSearchQuery::RemoteSearchQuery(QObject* parent)
    : Query(parent), m_model(new model::RemoteListModel(this)) {
    connect_requet_reload(&RemoteSearchQuery::queryChanged, this);
    connect_requet_reload(&RemoteSearchQuery::sortChanged, this);
    connect_requet_reload(&RemoteSearchQuery::tagsChanged, this);
}

auto RemoteSearchQuery::query() const -> const QString& { return m_query; }
void RemoteSearchQuery::setQuery(const QString& v) {
    if (m_query != v) {
        m_query = v;
        Q_EMIT queryChanged();
    }
}

auto RemoteSearchQuery::sort() const -> int { return m_sort; }
void RemoteSearchQuery::setSort(int v) {
    if (m_sort != v) {
        m_sort = v;
        Q_EMIT sortChanged();
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
    inner.setQuery(m_query);
    inner.setSort(static_cast<proto::RemoteSort>(m_sort));
    inner.setPage(page);
    inner.setRequiredTags(m_tags);
    req.setRemoteSearch(std::move(inner));

    auto self = QWatcher { this };
    spawn([self, backend, req = std::move(req), page, append]() mutable -> task<void> {
        auto result = co_await backend->send(std::move(req));
        co_await asio::post(asio::bind_executor(self->get_executor(), use_task));
        if (! self) co_return;

        self->inspect_set(result, [self, page, append](const proto::Response& rsp) {
            const auto&             sr = rsp.remoteSearch();
            QList<model::RemoteRow> rows;
            rows.reserve(sr.items().size());
            for (const auto& it : sr.items()) {
                rows.push_back(model::RemoteRow {
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
    connect_requet_reload(&RemoteDetailsQuery::itemIdChanged, this);
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
    inner.setId_proto(m_item_id);
    req.setRemoteDetails(std::move(inner));

    auto self = QWatcher { this };
    spawn([self, backend, req = std::move(req)]() mutable -> task<void> {
        auto result = co_await backend->send(std::move(req));
        co_await asio::post(asio::bind_executor(self->get_executor(), use_task));
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

void RemoteDownloadQuery::start(const QString& id) {
    if (id.isEmpty()) return;
    setStatus(Status::Querying);
    auto backend = App::instance()->backend();

    auto req   = proto::Request {};
    auto inner = proto::RemoteDownloadRequest {};
    inner.setId_proto(id);
    req.setRemoteDownload(std::move(inner));

    auto self = QWatcher { this };
    spawn([self, backend, req = std::move(req), id]() mutable -> task<void> {
        auto result = co_await backend->send(std::move(req));
        co_await asio::post(asio::bind_executor(self->get_executor(), use_task));
        if (! self) co_return;

        self->inspect_set(result, [self, id](const proto::Response& rsp) {
            const auto& dr = rsp.remoteDownload();
            if (dr.accepted()) {
                Q_EMIT self->accepted(id);
            } else {
                Q_EMIT self->rejected(id, dr.error());
            }
        });
        co_return;
    });
}

void RemoteDownloadQuery::uninstall(const QString& id) {
    if (id.isEmpty()) return;
    setStatus(Status::Querying);
    auto backend = App::instance()->backend();

    auto req   = proto::Request {};
    auto inner = proto::RemoteUninstallRequest {};
    inner.setId_proto(id);
    req.setRemoteUninstall(std::move(inner));

    auto self = QWatcher { this };
    spawn([self, backend, req = std::move(req), id]() mutable -> task<void> {
        auto result = co_await backend->send(std::move(req));
        co_await asio::post(asio::bind_executor(self->get_executor(), use_task));
        if (! self) co_return;

        self->inspect_set(result, [self, id](const proto::Response& rsp) {
            const auto& ur = rsp.remoteUninstall();
            if (ur.removed()) {
                Q_EMIT self->uninstalled(id);
            } else {
                Q_EMIT self->uninstallFailed(id, ur.error());
            }
        });
        co_return;
    });
}

} // namespace waywallen

#include "waywallen/query/remote_query.moc.cpp"
