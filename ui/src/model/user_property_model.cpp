module;
#include "waywallen/model/user_property_model.moc.h"

module waywallen;
import :model.user_property;

namespace waywallen::model
{

namespace
{

bool isSupported(const QString& type, bool has_options) {
    return type == QLatin1String("color") || type == QLatin1String("slider") ||
           type == QLatin1String("bool") || (type == QLatin1String("combo") && has_options);
}

QString propertiesSection() { return QStringLiteral("Properties"); }
QString userPropertiesSection() { return QStringLiteral("User properties"); }
QString builtinKind() { return QStringLiteral("property"); }
QString userKind() { return QStringLiteral("user"); }

QString jsonValueToWireString(const QJsonValue& v) {
    switch (v.type()) {
    case QJsonValue::Bool: return v.toBool() ? QStringLiteral("true") : QStringLiteral("false");
    case QJsonValue::Double: return QString::number(v.toDouble());
    case QJsonValue::String: return v.toString();
    case QJsonValue::Array: {
        QStringList parts;
        const auto  a = v.toArray();
        parts.reserve(a.size());
        for (const auto& e : a) parts << QString::number(e.toDouble(), 'f', 4);
        return parts.join(QLatin1Char(' '));
    }
    default: return {};
    }
}

QString coerceDefaultWireString(const QJsonValue& def, const QString& type) {
    // For colors WE may emit the default either as `"r g b"` string or as
    // a JSON array; normalise to space-separated floats either way.
    if (type == QLatin1String("color")) {
        if (def.isArray()) {
            QStringList parts;
            const auto  a = def.toArray();
            parts.reserve(a.size());
            for (const auto& e : a) parts << QString::number(e.toDouble(), 'f', 4);
            return parts.join(QLatin1Char(' '));
        }
        if (def.isString()) return def.toString();
    }
    if (type == QLatin1String("bool"))
        return def.toBool() ? QStringLiteral("true") : QStringLiteral("false");
    if (type == QLatin1String("slider")) return QString::number(def.toDouble());
    if (type == QLatin1String("combo")) return jsonValueToWireString(def);
    return jsonValueToWireString(def);
}

} // namespace

UserPropertyListModel::UserPropertyListModel(QObject* parent): QAbstractListModel(parent) {}

UserPropertyListModel::~UserPropertyListModel() = default;

int UserPropertyListModel::rowCount(const QModelIndex& parent) const {
    if (parent.isValid()) return 0;
    return static_cast<int>(m_entries.size());
}

QHash<int, QByteArray> UserPropertyListModel::roleNames() const {
    return {
        { KeyRole, "key" },
        { LabelRole, "label" },
        { TypeRole, "type" },
        { SupportedRole, "supported" },
        { MinValRole, "minVal" },
        { MaxValRole, "maxVal" },
        { CurrentValueRole, "currentValue" },
        { HasAlphaRole, "hasAlpha" },
        { OptionLabelsRole, "optionLabels" },
        { OptionValuesRole, "optionValues" },
        { SectionRole, "section" },
        { KindRole, "kind" },
    };
}

QVariant UserPropertyListModel::data(const QModelIndex& index, int role) const {
    if (! index.isValid()) return {};
    const auto row = index.row();
    if (row < 0 || row >= m_entries.size()) return {};
    const auto& e = m_entries.at(row);
    switch (role) {
    case KeyRole: return e.key;
    case LabelRole: return e.label;
    case TypeRole: return e.type;
    case SupportedRole: return e.supported;
    case MinValRole: return e.min_val;
    case MaxValRole: return e.max_val;
    case CurrentValueRole: return currentValueFor_(row);
    case OptionLabelsRole: return e.option_labels;
    case OptionValuesRole: return e.option_values;
    case HasAlphaRole: {
        const QString                   cv = currentValueFor_(row);
        static const QRegularExpression reSpaces(QStringLiteral("\\s+"));
        return cv.trimmed().split(reSpaces, Qt::SkipEmptyParts).size() >= 4;
    }
    case SectionRole: return e.section;
    case KindRole: return e.kind;
    default: return {};
    }
}

QString UserPropertyListModel::currentValueFor_(qsizetype row) const {
    const auto& e  = m_entries.at(row);
    const auto  it = m_overrides.constFind(e.key);
    if (it != m_overrides.constEnd() && ! it.value().isEmpty()) return it.value();
    return e.default_wire;
}

void UserPropertyListModel::setSchemaJson(const QString& v) {
    if (v == m_schema_json) return;
    m_schema_json = v;
    Q_EMIT schemaJsonChanged();
    rebuildEntries_();
}

void UserPropertyListModel::setOverridesJson(const QString& v) {
    if (v == m_overrides_json) return;
    m_overrides_json = v;
    Q_EMIT overridesJsonChanged();

    m_overrides.clear();
    if (! m_overrides_json.isEmpty()) {
        QJsonParseError err {};
        const auto      doc = QJsonDocument::fromJson(m_overrides_json.toUtf8(), &err);
        if (err.error == QJsonParseError::NoError && doc.isObject()) {
            const auto obj = doc.object();
            for (auto it = obj.constBegin(); it != obj.constEnd(); ++it) {
                if (it.value().isString()) m_overrides.insert(it.key(), it.value().toString());
            }
        }
    }
    // Every row's CurrentValue derivation depends on m_overrides.
    if (! m_entries.isEmpty()) {
        Q_EMIT dataChanged(index(0),
                           index(static_cast<int>(m_entries.size()) - 1),
                           { CurrentValueRole, HasAlphaRole });
    }
}

void UserPropertyListModel::rebuildEntries_() {
    beginResetModel();
    m_entries.clear();
    appendPredefinedEntries_();
    if (! m_schema_json.isEmpty()) {
        QJsonParseError err {};
        const auto      doc = QJsonDocument::fromJson(m_schema_json.toUtf8(), &err);
        if (err.error == QJsonParseError::NoError && doc.isObject()) {
            const auto obj = doc.object();
            QList<Entry> user_entries;
            user_entries.reserve(obj.size());
            for (auto it = obj.constBegin(); it != obj.constEnd(); ++it) {
                const auto v = it.value().toObject();
                Entry      e;
                e.key     = it.key();
                e.label   = v.value(QStringLiteral("text")).toString();
                e.section = userPropertiesSection();
                e.kind    = userKind();
                if (e.label.isEmpty()) e.label = e.key;
                e.type = v.value(QStringLiteral("type")).toString().toLower();
                if (v.value(QStringLiteral("options")).isArray()) {
                    const auto opts = v.value(QStringLiteral("options")).toArray();
                    e.option_labels.reserve(opts.size());
                    e.option_values.reserve(opts.size());
                    for (const auto& opt_value : opts) {
                        const auto opt = opt_value.toObject();
                        QString value  = jsonValueToWireString(opt.value(QStringLiteral("value")));
                        QString label  = opt.value(QStringLiteral("label")).toString();
                        if (label.isEmpty()) label = value;
                        e.option_values.append(std::move(value));
                        e.option_labels.append(std::move(label));
                    }
                }
                e.supported    = isSupported(e.type, ! e.option_values.isEmpty());
                e.min_val      = v.value(QStringLiteral("min")).toDouble(0.0);
                e.max_val      = v.value(QStringLiteral("max")).toDouble(1.0);
                e.default_wire = coerceDefaultWireString(v.value(QStringLiteral("value")), e.type);
                e.order        = v.value(QStringLiteral("order")).toDouble(0.0);
                user_entries.append(std::move(e));
            }
            std::sort(user_entries.begin(), user_entries.end(), [](const Entry& a, const Entry& b) {
                return a.order < b.order;
            });
            m_entries.append(user_entries);
        }
    }
    endResetModel();
    Q_EMIT countChanged();
}

void UserPropertyListModel::appendPredefinedEntries_() {
    auto make = [](QString key, QString label, QString type, QString value) {
        Entry e;
        e.key          = std::move(key);
        e.label        = std::move(label);
        e.type         = std::move(type);
        e.section      = propertiesSection();
        e.kind         = builtinKind();
        e.supported    = true;
        e.default_wire = std::move(value);
        return e;
    };

    auto scheme = make(QStringLiteral("waywallen.scheme_color"),
                       QStringLiteral("Scheme color"),
                       QStringLiteral("color"),
                       QStringLiteral("0.0000 0.0000 0.0000 1.0000"));
    m_entries.append(std::move(scheme));

    auto fill = make(QStringLiteral("waywallen.fill_mode"),
                     QStringLiteral("Fill mode"),
                     QStringLiteral("combo"),
                     QStringLiteral("preserve_aspect_crop"));
    fill.option_labels = {
        QStringLiteral("Stretch"),
        QStringLiteral("Fit"),
        QStringLiteral("Crop"),
        QStringLiteral("Center"),
    };
    fill.option_values = {
        QStringLiteral("stretched"),
        QStringLiteral("preserve_aspect_fit"),
        QStringLiteral("preserve_aspect_crop"),
        QStringLiteral("centered"),
    };
    m_entries.append(std::move(fill));

    auto rotation = make(QStringLiteral("waywallen.rotation"),
                         QStringLiteral("Rotation"),
                         QStringLiteral("combo"),
                         QStringLiteral("normal"));
    rotation.option_labels = {
        QStringLiteral("0°"),
        QStringLiteral("90°"),
        QStringLiteral("180°"),
        QStringLiteral("270°"),
    };
    rotation.option_values = {
        QStringLiteral("normal"),
        QStringLiteral("cw_90"),
        QStringLiteral("cw_180"),
        QStringLiteral("cw_270"),
    };
    m_entries.append(std::move(rotation));

    auto location_x = make(QStringLiteral("waywallen.location_x"),
                           QStringLiteral("Horizontal location"),
                           QStringLiteral("slider"),
                           QStringLiteral("50"));
    location_x.min_val = 0.0;
    location_x.max_val = 100.0;
    m_entries.append(std::move(location_x));

    auto location_y = make(QStringLiteral("waywallen.location_y"),
                           QStringLiteral("Vertical location"),
                           QStringLiteral("slider"),
                           QStringLiteral("50"));
    location_y.min_val = 0.0;
    location_y.max_val = 100.0;
    m_entries.append(std::move(location_y));
}

void UserPropertyListModel::setValue(const QString& key, const QString& value) {
    m_overrides.insert(key, value);
    notifyCurrentChanged_(key);
    Q_EMIT valueChanged(key, value);
}

void UserPropertyListModel::resetAll() {
    for (const auto& e : m_entries) {
        m_overrides.insert(e.key, e.default_wire);
        notifyCurrentChanged_(e.key);
        Q_EMIT valueChanged(e.key, e.default_wire);
    }
}

void UserPropertyListModel::resetPredefinedProperties() {
    for (const auto& e : m_entries) {
        if (e.kind != builtinKind()) continue;
        m_overrides.insert(e.key, e.default_wire);
        notifyCurrentChanged_(e.key);
        Q_EMIT valueChanged(e.key, e.default_wire);
    }
}

void UserPropertyListModel::resetUserProperties() {
    for (const auto& e : m_entries) {
        if (e.kind != userKind()) continue;
        m_overrides.insert(e.key, e.default_wire);
        notifyCurrentChanged_(e.key);
        Q_EMIT valueChanged(e.key, e.default_wire);
    }
}

void UserPropertyListModel::notifyCurrentChanged_(const QString& key) {
    for (qsizetype i = 0; i < m_entries.size(); ++i) {
        if (m_entries.at(i).key == key) {
            const auto idx = index(static_cast<int>(i));
            Q_EMIT dataChanged(idx, idx, { CurrentValueRole, HasAlphaRole });
            return;
        }
    }
}

} // namespace waywallen::model

#include "waywallen/model/user_property_model.moc.cpp"
