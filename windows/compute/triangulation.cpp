// triangulation.cpp - C++ port of game/triangulation.lua's ray-triangulation
// math, for bridge_server.py's POST /compute/triangulation route (used when
// windows/compute/triangulation.py is absent and this has been compiled to
// triangulation.exe - see resolve_compute_script() in bridge_server.py).
//
// NOT COMPILED OR TESTED ON THIS MACHINE - no g++/cl/gcc toolchain was found
// here. Compile with e.g.:
//     g++ -O2 -std=c++17 -o triangulation.exe triangulation.cpp
// and drop the resulting triangulation.exe next to this file - the bridge
// picks it up automatically (it only uses triangulation.py if present, so
// this file has zero effect until compiled). Once compiled, cross-check it
// against test/test_compute_triangulation.py's vectors before trusting it
// for real navigation.
//
// Reads one JSON object from stdin, writes one JSON object to stdout - same
// contract as triangulation.py (see that file's docstring for the exact
// shape). Hand-rolled minimal JSON parse/emit, no external dependencies -
// matches this project's existing style (see windows/craftos_shim.lua's
// jsonEncode/jsonDecode for the same idea in Lua). Only handles the fixed
// input shape this script expects, not arbitrary JSON.

#include <cctype>
#include <cmath>
#include <iostream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

// ---- minimal JSON value ----

struct JsonValue {
    enum Type { NUL, BOOL, NUMBER, STRING, ARRAY, OBJECT } type = NUL;
    bool b = false;
    double num = 0;
    std::string str;
    std::vector<JsonValue> arr;
    std::map<std::string, JsonValue> obj;

    bool has(const std::string& key) const {
        return type == OBJECT && obj.count(key) > 0;
    }
    const JsonValue& at(const std::string& key) const {
        return obj.at(key);
    }
    double number(const std::string& key, double def) const {
        if (has(key)) return obj.at(key).num;
        return def;
    }
};

// ---- minimal recursive-descent JSON parser (object/array/number/string/
// true/false/null - enough for this script's fixed input shape, not a
// general-purpose parser) ----

class JsonParser {
public:
    explicit JsonParser(const std::string& s) : s_(s), pos_(0) {}

    JsonValue parse() {
        skipWs();
        return parseValue();
    }

private:
    const std::string& s_;
    size_t pos_;

    void skipWs() {
        while (pos_ < s_.size() && std::isspace((unsigned char)s_[pos_])) pos_++;
    }

    char peek() { return pos_ < s_.size() ? s_[pos_] : '\0'; }

    JsonValue parseValue() {
        skipWs();
        char c = peek();
        if (c == '{') return parseObject();
        if (c == '[') return parseArray();
        if (c == '"') return parseString();
        if (c == 't' || c == 'f') return parseBool();
        if (c == 'n') { pos_ += 4; return JsonValue(); } // "null"
        return parseNumber();
    }

    JsonValue parseObject() {
        JsonValue v;
        v.type = JsonValue::OBJECT;
        pos_++; // '{'
        skipWs();
        if (peek() == '}') { pos_++; return v; }
        while (true) {
            skipWs();
            JsonValue key = parseString();
            skipWs();
            pos_++; // ':'
            JsonValue val = parseValue();
            v.obj[key.str] = val;
            skipWs();
            if (peek() == ',') { pos_++; continue; }
            if (peek() == '}') { pos_++; break; }
            break;
        }
        return v;
    }

    JsonValue parseArray() {
        JsonValue v;
        v.type = JsonValue::ARRAY;
        pos_++; // '['
        skipWs();
        if (peek() == ']') { pos_++; return v; }
        while (true) {
            JsonValue val = parseValue();
            v.arr.push_back(val);
            skipWs();
            if (peek() == ',') { pos_++; continue; }
            if (peek() == ']') { pos_++; break; }
            break;
        }
        return v;
    }

    JsonValue parseString() {
        JsonValue v;
        v.type = JsonValue::STRING;
        pos_++; // opening quote
        std::string out;
        while (pos_ < s_.size() && s_[pos_] != '"') {
            char c = s_[pos_];
            if (c == '\\' && pos_ + 1 < s_.size()) {
                char n = s_[pos_ + 1];
                switch (n) {
                    case 'n': out += '\n'; break;
                    case 't': out += '\t'; break;
                    case 'r': out += '\r'; break;
                    case '"': out += '"'; break;
                    case '\\': out += '\\'; break;
                    default: out += n; break;
                }
                pos_ += 2;
            } else {
                out += c;
                pos_++;
            }
        }
        pos_++; // closing quote
        v.str = out;
        return v;
    }

    JsonValue parseBool() {
        JsonValue v;
        v.type = JsonValue::BOOL;
        if (s_.compare(pos_, 4, "true") == 0) { v.b = true; pos_ += 4; }
        else { v.b = false; pos_ += 5; }
        return v;
    }

    JsonValue parseNumber() {
        JsonValue v;
        v.type = JsonValue::NUMBER;
        size_t start = pos_;
        if (peek() == '-') pos_++;
        while (pos_ < s_.size() && (std::isdigit((unsigned char)s_[pos_]) || s_[pos_] == '.' ||
                                     s_[pos_] == 'e' || s_[pos_] == 'E' || s_[pos_] == '+' || s_[pos_] == '-')) {
            pos_++;
        }
        v.num = std::stod(s_.substr(start, pos_ - start));
        return v;
    }
};

std::string jsonNumber(double d) {
    std::ostringstream out;
    out.precision(17);
    out << d;
    return out.str();
}

// ---- vector/quaternion math (mirrors triangulation.lua/triangulation.py
// exactly - same formulas, same 3x3 Cramer's-rule solve) ----

struct Vec3 { double x = 0, y = 0, z = 0; };
struct Quat { double x = 0, y = 0, z = 0, w = 1; };

Vec3 vecFromJson(const JsonValue& v) {
    return Vec3{ v.number("x", 0), v.number("y", 0), v.number("z", 0) };
}

Quat quatFromJson(const JsonValue& v) {
    return Quat{ v.number("x", 0), v.number("y", 0), v.number("z", 0), v.number("w", 1) };
}

Vec3 rotateByQuaternion(const Quat& q, const Vec3& v) {
    double tx = 2 * (q.y * v.z - q.z * v.y);
    double ty = 2 * (q.z * v.x - q.x * v.z);
    double tz = 2 * (q.x * v.y - q.y * v.x);
    double cx = q.y * tz - q.z * ty;
    double cy = q.z * tx - q.x * tz;
    double cz = q.x * ty - q.y * tx;
    return Vec3{
        v.x + q.w * tx + cx,
        v.y + q.w * ty + cy,
        v.z + q.w * tz + cz,
    };
}

Vec3 normalizeVec(const Vec3& v) {
    double len = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    if (len < 1e-9) return Vec3{ 0, 0, 0 };
    return Vec3{ v.x / len, v.y / len, v.z / len };
}

double det3(const double m[3][3]) {
    return m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
         - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
         + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
}

bool solve3x3(double a[3][3], double b[3], double result[3]) {
    double d = det3(a);
    if (std::fabs(d) < 1e-9) return false;

    for (int col = 0; col < 3; col++) {
        double r[3][3];
        for (int i = 0; i < 3; i++)
            for (int j = 0; j < 3; j++)
                r[i][j] = a[i][j];
        for (int i = 0; i < 3; i++) r[i][col] = b[i];
        result[col] = det3(r) / d;
    }
    return true;
}

int main() {
    std::ostringstream buf;
    buf << std::cin.rdbuf();
    std::string input = buf.str();

    JsonValue req;
    try {
        JsonParser parser(input);
        req = parser.parse();
    } catch (...) {
        std::cout << "{\"ok\": false, \"error\": \"failed to parse input JSON\"}" << std::endl;
        return 0;
    }

    Vec3 forward{ 1, 0, 0 };
    if (req.has("forward")) forward = vecFromJson(req.at("forward"));

    double qsign[3] = { 1, 1, 1 };
    if (req.has("qsign") && req.at("qsign").type == JsonValue::ARRAY) {
        const auto& arr = req.at("qsign").arr;
        for (size_t i = 0; i < arr.size() && i < 3; i++) qsign[i] = arr[i].num;
    }

    std::vector<JsonValue> rays;
    if (req.has("rays") && req.at("rays").type == JsonValue::ARRAY) {
        rays = req.at("rays").arr;
    }

    if (rays.size() < 2) {
        std::cout << "{\"ok\": false, \"error\": \"need at least 2 rays\"}" << std::endl;
        return 0;
    }

    double a[3][3] = { {0, 0, 0}, {0, 0, 0}, {0, 0, 0} };
    double b[3] = { 0, 0, 0 };

    for (const auto& rayJson : rays) {
        if (!rayJson.has("origin") || !rayJson.has("quat")) {
            std::cout << "{\"ok\": false, \"error\": \"bad input: ray missing origin/quat\"}" << std::endl;
            return 0;
        }
        Vec3 origin = vecFromJson(rayJson.at("origin"));
        Quat quat = quatFromJson(rayJson.at("quat"));

        Quat sq{ quat.x * qsign[0], quat.y * qsign[1], quat.z * qsign[2], quat.w };
        Vec3 d = normalizeVec(rotateByQuaternion(sq, forward));

        double m[3][3] = {
            { 1 - d.x * d.x,     -d.x * d.y,     -d.x * d.z },
            {     -d.y * d.x, 1 - d.y * d.y,     -d.y * d.z },
            {     -d.z * d.x,     -d.z * d.y, 1 - d.z * d.z },
        };

        for (int i = 0; i < 3; i++)
            for (int j = 0; j < 3; j++)
                a[i][j] += m[i][j];

        b[0] += m[0][0] * origin.x + m[0][1] * origin.y + m[0][2] * origin.z;
        b[1] += m[1][0] * origin.x + m[1][1] * origin.y + m[1][2] * origin.z;
        b[2] += m[2][0] * origin.x + m[2][1] * origin.y + m[2][2] * origin.z;
    }

    double result[3];
    if (!solve3x3(a, b, result)) {
        std::cout << "{\"ok\": false, \"error\": \"rays are parallel or the system is degenerate\"}" << std::endl;
        return 0;
    }

    std::cout << "{\"ok\": true, \"x\": " << jsonNumber(result[0])
               << ", \"y\": " << jsonNumber(result[1])
               << ", \"z\": " << jsonNumber(result[2]) << "}" << std::endl;
    return 0;
}
