module;
#include "QExtra/macro_qt.hpp"
#include <QtCore/QAbstractListModel>

#ifdef Q_MOC_RUN
#    include "waywallen/model/remote_model.moc"
#endif

export module waywallen:model.remote;
export import qextra;

namespace waywallen::model
{

export struct RemoteRow {
    QString id;
    QString title;
    QString previewUrl;
    QString author;
    bool    installed { false };
};

export class RemoteListModel : public QAbstractListModel {
    Q_OBJECT
    QML_ANONYMOUS

    Q_PROPERTY(int count READ count NOTIFY countChanged FINAL)

public:
    enum Role
    {
        ItemIdRole = Qt::UserRole + 1,
        TitleRole,
        PreviewUrlRole,
        AuthorRole,
        InstalledRole,
    };

    explicit RemoteListModel(QObject* parent = nullptr);

    int                    rowCount(const QModelIndex& parent = QModelIndex()) const override;
    QVariant               data(const QModelIndex& index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    auto count() const -> int { return static_cast<int>(m_rows.size()); }

    void             reset(QList<RemoteRow> rows);
    void             append(const QList<RemoteRow>& rows);
    Q_INVOKABLE void setInstalled(const QString& id, bool installed);

    Q_INVOKABLE QVariantMap get(int row) const;

    Q_SIGNAL void countChanged();

private:
    QList<RemoteRow> m_rows;
};

} // namespace waywallen::model
