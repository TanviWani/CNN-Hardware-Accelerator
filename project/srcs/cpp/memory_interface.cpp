// Adapted from the vector DPI/VPI backend in ece464-564-hw-miniproj/Solution.
// Adds independent instance IDs and presence/address queries for project checks.
//==========================================================================
// memory_interface.cpp
//
// Common byte-addressable memory backend for independent DRAM instances.
//
// Each memory instance uses:
//
//     std::unordered_map<uint64_t, uint8_t>
//
// The line width and endianness determine how bytes are packed/unpacked.
//
// Memory IDs:
//     IDs are selected by each SV instance (0 and 1 for two-port DRAM).
//
// DAT format:
//
//     @00000000 03020100
//     @00000004 07060504
//
// For little-endian, the lowest-address byte occupies data[7:0].
//
//==========================================================================

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

#ifdef MEMORY_INTERFACE_VPI
#include <vpi_user.h>
#else
#include <svdpi.h>
#endif


//==========================================================================
// Memory IDs
//==========================================================================




//==========================================================================
// Addressing modes
//
// DIRECT:
//     The supplied address is a line/word index.
//
//     For a 32-bit line:
//         address 0 -> byte address 0
//         address 1 -> byte address 4
//         address 2 -> byte address 8
//
// BYTE:
//     The supplied address is already a byte address.
//
//     For a 32-bit line:
//         address 0 -> byte address 0
//         address 4 -> byte address 4
//         address 8 -> byte address 8
//
// Internally, memory is always stored as a byte-addressable map.
//==========================================================================

static constexpr unsigned ADDRESS_MODE_DIRECT = 0;
static constexpr unsigned ADDRESS_MODE_BYTE   = 1;


//==========================================================================
// Memory line
//
// Byte 0 is packed bits [7:0].
// Byte 1 is packed bits [15:8].
// etc.
//
// Endianness controls how these packed bytes map onto increasing memory
// addresses.  The line itself therefore has simulator-independent packed
// vector semantics.
//==========================================================================

using MemoryLine = std::vector<uint8_t>;


//==========================================================================
// Memory
//==========================================================================

class Memory
{
public:

    bool byte_exists(uint64_t address) const { return memory_.count(address) != 0; }
    mutable std::vector<uint64_t> address_cache;
    mutable bool addresses_dirty=true;
    const std::vector<uint64_t> &stored_addresses() const {
        if (addresses_dirty) {
            address_cache.clear();
            for (const auto &entry : memory_) address_cache.push_back(entry.first);
            std::sort(address_cache.begin(), address_cache.end());
            addresses_dirty=false;
        }
        return address_cache;
    }

    //----------------------------------------------------------------------
    // Clear all memory
    //----------------------------------------------------------------------

    void clear()
    {
        memory_.clear();
        addresses_dirty=true;
    }


    //----------------------------------------------------------------------
    // Read one raw byte
    //
    // The address is ALWAYS the canonical internal byte address.
    //
    // This bypasses:
    //   - line width
    //   - endianness
    //   - ADDRESS_MODE
    //
    // Missing bytes are returned as zero.
    //----------------------------------------------------------------------

    uint8_t read_byte(
        uint64_t byte_address) const
    {
        const auto it =
            memory_.find(byte_address);

        if (it == memory_.end())
            return 0;

        return it->second;
    }


    //----------------------------------------------------------------------
    // Dump raw canonical memory to a binary file.
    //
    // Writes exactly:
    //
    //     [start_byte_address, start_byte_address + size)
    //
    // This is analogous to extracting a raw memory/section image.
    //
    // No endian conversion is performed.
    // No ADDRESS_MODE conversion is performed.
    // Missing bytes are written as 0x00.
    //----------------------------------------------------------------------

    bool dump_binary(
        const std::string &filename,
        uint64_t start_byte_address,
        uint64_t size) const
    {
        std::ofstream file(
            filename,
            std::ios::binary
        );

        if (!file.is_open()) {

            std::fprintf(
                stderr,
                "ERROR::[memory] Could not open '%s' for binary writing\n",
                filename.c_str()
            );

            return false;
        }

        for (uint64_t offset = 0;
             offset < size;
             ++offset) {

            const uint8_t value =
                read_byte(
                    start_byte_address + offset
                );

            const char byte =
                static_cast<char>(value);

            file.write(
                &byte,
                1
            );

            if (!file.good()) {

                std::fprintf(
                    stderr,
                    "ERROR::[memory] Error writing binary file '%s'\n",
                    filename.c_str()
                );

                return false;
            }
        }

        file.close();

        std::printf(
            "INFO::[memory] Dumped %llu raw bytes "
            "[0x%llx, 0x%llx) to '%s'\n",
            static_cast<unsigned long long>(size),
            static_cast<unsigned long long>(
                start_byte_address
            ),
            static_cast<unsigned long long>(
                start_byte_address + size
            ),
            filename.c_str()
        );

        return true;
    }


    //----------------------------------------------------------------------
    // Read one line
    //
    // line_width is in bits.
    //
    // Example:
    //
    // memory:
    //
    //   0x08 -> 08
    //   0x09 -> 09
    //   0x0a -> 0a
    //   0x0b -> 0b
    //
    // read_line(0x08, 32, true)
    //
    //   -> 0x0b0a0908
    //
    // Missing bytes are returned as zero.
    //----------------------------------------------------------------------

    MemoryLine read_line(
        uint64_t address,
        unsigned line_width,
        bool little_endian,
        unsigned address_mode) const
    {
        if (!valid_line_width(line_width) ||
            !valid_address_mode(address_mode))
            return {};

        const unsigned num_bytes =
            line_width / 8;

        const uint64_t byte_address =
            to_byte_address(
                address,
                line_width,
                address_mode
            );

        MemoryLine data(
            num_bytes,
            0
        );

        for (unsigned memory_index = 0;
             memory_index < num_bytes;
             ++memory_index) {

            uint8_t value = 0;

            const auto it =
                memory_.find(
                    byte_address + memory_index
                );

            if (it != memory_.end())
                value = it->second;

            const unsigned data_index =
                little_endian
                    ? memory_index
                    : (num_bytes - 1u - memory_index);

            data[data_index] = value;
        }

        return data;
    }


    //----------------------------------------------------------------------
    // Check whether every byte in a line exists
    //----------------------------------------------------------------------

    bool line_exists(
        uint64_t address,
        unsigned line_width,
        unsigned address_mode) const
    {
        if (!valid_line_width(line_width) ||
            !valid_address_mode(address_mode))
            return false;

        const unsigned num_bytes = line_width / 8;

        const uint64_t byte_address =
            to_byte_address(
                address,
                line_width,
                address_mode
            );

        for (unsigned i = 0; i < num_bytes; ++i) {

            if (memory_.find(byte_address + i) == memory_.end())
                return false;
        }

        return true;
    }


    //----------------------------------------------------------------------
    // Write one line
    //
    // Example:
    //
    // write_line(
    //     0x08,
    //     0x0b0a0908,
    //     32,
    //     true
    // );
    //
    // produces:
    //
    //   0x08 -> 08
    //   0x09 -> 09
    //   0x0a -> 0a
    //   0x0b -> 0b
    //----------------------------------------------------------------------

    bool write_line(
        uint64_t address,
        const MemoryLine &data,
        unsigned line_width,
        bool little_endian,
        unsigned address_mode)
    {
        if (!valid_line_width(line_width) ||
            !valid_address_mode(address_mode))
            return false;

        const unsigned num_bytes =
            line_width / 8;

        if (data.size() != num_bytes) {

            std::fprintf(
                stderr,
                "ERROR::[memory] "
                "Line data size mismatch: "
                "width=%u requires %u bytes, got %zu\n",
                line_width,
                num_bytes,
                data.size()
            );

            return false;
        }

        const uint64_t byte_address =
            to_byte_address(
                address,
                line_width,
                address_mode
            );

        for (unsigned memory_index = 0;
             memory_index < num_bytes;
             ++memory_index) {

            const unsigned data_index =
                little_endian
                    ? memory_index
                    : (num_bytes - 1u - memory_index);

            addresses_dirty=true;

            memory_[byte_address + memory_index] =
                data[data_index];
        }

        return true;
    }


    //----------------------------------------------------------------------
    // Load DAT file
    //
    // Existing memory is cleared first.
    //----------------------------------------------------------------------

    bool load(
        const std::string &filename,
        unsigned line_width,
        bool little_endian,
        unsigned address_mode)
    {
        if (!valid_line_width(line_width)) {

            std::fprintf(
                stderr,
                "ERROR::[memory] Invalid line width: %u\n",
                line_width
            );

            return false;
        }

        if (!valid_address_mode(address_mode)) {

            std::fprintf(
                stderr,
                "ERROR::[memory] Invalid address mode: %u\n",
                address_mode
            );

            return false;
        }

        std::ifstream file(filename);

        if (!file.is_open()) {

            std::fprintf(
                stderr,
                "ERROR::[memory] Could not open '%s' for reading\n",
                filename.c_str()
            );

            return false;
        }

        clear();

        std::string line;
        uint64_t records = 0;

        while (std::getline(file, line)) {

            uint64_t address = 0;
            MemoryLine data;

            if (!parse_dat_line(
                    line,
                    address,
                    data,
                    line_width))
                continue;

            if (!write_line(
                    address,
                    data,
                    line_width,
                    little_endian,
                    address_mode)) {

                return false;
            }

            const MemoryLine verify_data =
                read_line(
                    address,
                    line_width,
                    little_endian,
                    address_mode
                );

            ++records;
        }

        std::printf(
            "INFO::[memory] Loaded %llu records from '%s'\n",
            static_cast<unsigned long long>(records),
            filename.c_str()
        );

        return true;
    }


    //----------------------------------------------------------------------
    // Dump DAT file
    //
    // Lines are aligned to line_width.
    //
    // Only lines containing at least one stored byte are emitted.
    //----------------------------------------------------------------------

    bool dump(
        const std::string &filename,
        unsigned line_width,
        bool little_endian,
        unsigned address_mode) const
    {
        if (!valid_line_width(line_width)) {

            std::fprintf(
                stderr,
                "ERROR::[memory] Invalid line width: %u\n",
                line_width
            );

            return false;
        }

        if (!valid_address_mode(address_mode)) {

            std::fprintf(
                stderr,
                "ERROR::[memory] Invalid address mode: %u\n",
                address_mode
            );

            return false;
        }

        std::ofstream file(filename);

        if (!file.is_open()) {

            std::fprintf(
                stderr,
                "ERROR::[memory] Could not open '%s' for writing\n",
                filename.c_str()
            );

            return false;
        }

        const uint64_t line_bytes = line_width / 8;


        //------------------------------------------------------------------
        // Find all byte-aligned line addresses represented by the byte map.
        //
        // The internal memory representation is always byte-addressable.
        //------------------------------------------------------------------

        std::vector<uint64_t> byte_addresses;

        byte_addresses.reserve(memory_.size());

        for (const auto &entry : memory_) {

            const uint64_t line_byte_address =
                (entry.first / line_bytes) * line_bytes;

            byte_addresses.push_back(line_byte_address);
        }


        //------------------------------------------------------------------
        // Sort and remove duplicates.
        //------------------------------------------------------------------

        std::sort(
            byte_addresses.begin(),
            byte_addresses.end()
        );

        byte_addresses.erase(
            std::unique(
                byte_addresses.begin(),
                byte_addresses.end()
            ),
            byte_addresses.end()
        );


        //------------------------------------------------------------------
        // Write DAT records.
        //
        // BYTE mode:
        //     internal byte address 0,4,8 -> DAT address 0,4,8
        //
        // DIRECT mode:
        //     internal byte address 0,4,8 -> DAT address 0,1,2
        //------------------------------------------------------------------

        for (const uint64_t byte_address : byte_addresses) {

            const uint64_t external_address =
                from_byte_address(
                    byte_address,
                    line_width,
                    address_mode
                );

            const MemoryLine data =
                read_line(
                    external_address,
                    line_width,
                    little_endian,
                    address_mode
                );

            file
                << '@'
                << std::hex
                << std::setfill('0')
                << std::setw(8)
                << external_address
                << ' '
                << line_to_hex(data)
                << '\n';
        }

        std::printf(
            "INFO::[memory] Dumped %llu records to '%s'\n",
            static_cast<unsigned long long>(
                byte_addresses.size()
            ),
            filename.c_str()
        );

        return true;
    }


    //----------------------------------------------------------------------
    // Compare against reference DAT file.
    //
    // Comparison is PER LINE:
    //
    //                       matching reference lines
    // percent = 100.0 * --------------------------------
    //                       total reference lines
    //
    // A reference line only matches if:
    //
    //   1. every byte in that line exists in actual memory
    //   2. the assembled line value equals the reference value
    //
    // Extra locations in actual memory are ignored.
    //----------------------------------------------------------------------

    double compare(
        const std::string &filename,
        unsigned line_width,
        bool little_endian,
        unsigned address_mode) const
    {
        if (!valid_line_width(line_width)) {

            std::fprintf(
                stderr,
                "ERROR::[memory] Invalid line width: %u\n",
                line_width
            );

            return 0.0;
        }

        if (!valid_address_mode(address_mode)) {

            std::fprintf(
                stderr,
                "ERROR::[memory] Invalid address mode: %u\n",
                address_mode
            );

            return 0.0;
        }

        std::ifstream file(filename);

        if (!file.is_open()) {

            std::fprintf(
                stderr,
                "ERROR::[memory] Could not open reference '%s'\n",
                filename.c_str()
            );

            return 0.0;
        }

        uint64_t matching = 0;
        uint64_t total    = 0;

        std::string line;

        while (std::getline(file, line)) {

            uint64_t address = 0;
            MemoryLine expected;

            if (!parse_dat_line(
                    line,
                    address,
                    expected,
                    line_width))
                continue;

            ++total;

            if (!line_exists(
                    address,
                    line_width,
                    address_mode))
                continue;

            const MemoryLine actual =
                read_line(
                    address,
                    line_width,
                    little_endian,
                    address_mode
                );

            if (actual == expected)
                ++matching;
        }


        //------------------------------------------------------------------
        // Empty reference
        //----------------------------------------------------------------------

        if (total == 0) {

            std::fprintf(
                stderr,
                "WARNING::[memory] Reference '%s' contains no records\n",
                filename.c_str()
            );

            return 100.0;
        }


        //------------------------------------------------------------------
        // Percentage
        //----------------------------------------------------------------------

        const double percentage =
            100.0 *
            static_cast<double>(matching) /
            static_cast<double>(total);

        std::printf(
            "INFO::[memory] Compare '%s': "
            "%llu / %llu lines matched (%0.2f%%)\n",
            filename.c_str(),
            static_cast<unsigned long long>(matching),
            static_cast<unsigned long long>(total),
            percentage
        );

        return percentage;
    }


private:

    //----------------------------------------------------------------------
    // Byte-addressable sparse storage
    //----------------------------------------------------------------------

    std::unordered_map<uint64_t, uint8_t> memory_;


    //----------------------------------------------------------------------
    // Width validation
    //
    // Line data is represented as a byte vector.  The backend therefore
    // has no 64-bit data-width limit.  Lines must be byte aligned.
    //----------------------------------------------------------------------

    static bool valid_line_width(
        unsigned line_width)
    {
        return
            line_width >= 8 &&
            (line_width % 8) == 0;
    }


    //----------------------------------------------------------------------
    // Address mode validation
    //----------------------------------------------------------------------

    static bool valid_address_mode(
        unsigned address_mode)
    {
        return
            address_mode == ADDRESS_MODE_DIRECT ||
            address_mode == ADDRESS_MODE_BYTE;
    }


    //----------------------------------------------------------------------
    // Convert an externally visible address to the canonical internal
    // byte address.
    //
    // DIRECT mode:
    //
    //     external address is a line index
    //
    //     32-bit:
    //         0 -> byte 0
    //         1 -> byte 4
    //         2 -> byte 8
    //
    // BYTE mode:
    //
    //     external address is already a byte address
    //
    //     32-bit:
    //         0 -> byte 0
    //         4 -> byte 4
    //         8 -> byte 8
    //----------------------------------------------------------------------

    static uint64_t to_byte_address(
        uint64_t address,
        unsigned line_width,
        unsigned address_mode)
    {
        if (address_mode == ADDRESS_MODE_DIRECT)
            return address * (line_width / 8);

        return address;
    }


    //----------------------------------------------------------------------
    // Convert the canonical internal byte address back to the externally
    // visible address used by DAT files.
    //----------------------------------------------------------------------

    static uint64_t from_byte_address(
        uint64_t byte_address,
        unsigned line_width,
        unsigned address_mode)
    {
        if (address_mode == ADDRESS_MODE_DIRECT)
            return byte_address / (line_width / 8);

        return byte_address;
    }


    //----------------------------------------------------------------------
    // Parse:
    //
    //     @00000000 03020100
    //
    // Blank lines and lines beginning with '#' are ignored.
    // Inline '#' comments are also supported.
    //----------------------------------------------------------------------

    static int hex_value(
        char c)
    {
        if (c >= '0' && c <= '9')
            return c - '0';

        if (c >= 'a' && c <= 'f')
            return 10 + (c - 'a');

        if (c >= 'A' && c <= 'F')
            return 10 + (c - 'A');

        return -1;
    }


    //----------------------------------------------------------------------
    // Convert packed-vector bytes to DAT hexadecimal text.
    //
    // data[0] is the least-significant packed byte, therefore text is
    // emitted from the highest byte down to byte zero.
    //----------------------------------------------------------------------

    static std::string line_to_hex(
        const MemoryLine &data)
    {
        static const char digits[] =
            "0123456789abcdef";

        std::string result;

        result.reserve(
            data.size() * 2u
        );

        for (auto it = data.rbegin();
             it != data.rend();
             ++it) {

            result.push_back(
                digits[(*it >> 4) & 0x0f]
            );

            result.push_back(
                digits[*it & 0x0f]
            );
        }

        return result;
    }


    //----------------------------------------------------------------------
    // Parse:
    //
    //     @00000000 03020100
    //
    // DAT data is converted directly to MemoryLine.  It never passes
    // through uint64_t, so line widths greater than 64 bits are supported.
    //----------------------------------------------------------------------

    static bool parse_dat_line(
        const std::string &input,
        uint64_t &address,
        MemoryLine &data,
        unsigned line_width)
    {
        std::string line = input;

        const std::size_t comment =
            line.find('#');

        if (comment != std::string::npos)
            line.erase(comment);

        const std::size_t first =
            line.find_first_not_of(
                " \t\r\n"
            );

        if (first == std::string::npos)
            return false;

        line.erase(
            0,
            first
        );

        if (line.empty() ||
            line[0] != '@')
            return false;

        line.erase(
            0,
            1
        );

        std::istringstream stream(line);

        std::string address_text;
        std::string data_text;

        stream
            >> address_text
            >> data_text;

        if (stream.fail())
            return false;

        try {

            std::size_t consumed = 0;

            address =
                std::stoull(
                    address_text,
                    &consumed,
                    16
                );

            if (consumed != address_text.size())
                return false;
        }
        catch (...) {
            return false;
        }

        const unsigned num_bytes =
            line_width / 8;

        const std::size_t required_digits =
            static_cast<std::size_t>(
                num_bytes
            ) * 2u;

        if (data_text.size() > required_digits) {

            std::fprintf(
                stderr,
                "ERROR::[memory] "
                "DAT value '%s' exceeds %u-bit line width\n",
                data_text.c_str(),
                line_width
            );

            return false;
        }

        for (const char c : data_text) {

            if (hex_value(c) < 0)
                return false;
        }

        if (data_text.size() < required_digits) {

            data_text.insert(
                0,
                required_digits - data_text.size(),
                '0'
            );
        }

        data.assign(
            num_bytes,
            0
        );

        for (unsigned byte_index = 0;
             byte_index < num_bytes;
             ++byte_index) {

            const std::size_t pos =
                data_text.size()
                - 2u * (byte_index + 1u);

            const int hi =
                hex_value(
                    data_text[pos]
                );

            const int lo =
                hex_value(
                    data_text[pos + 1u]
                );

            data[byte_index] =
                static_cast<uint8_t>(
                    (hi << 4) | lo
                );
        }

        return true;
    }
};


//==========================================================================
// Memory instances
//
// All memory IDs select independent byte stores using the same implementation.
//==========================================================================

// Each SV instance selects an independent, nonnegative ID.
static std::unordered_map<int, Memory> memories;
static Memory *get_memory(int memory_id) {
    if (memory_id < 0) return nullptr;
    return &memories[memory_id];
}

//==========================================================================
// DPI packed-vector conversion
//
// SystemVerilog packed bit vectors are represented by DPI as arrays of
// svBitVecVal words.
//
//     words[0] -> bits [31:0]
//     words[1] -> bits [63:32]
//     ...
//
// MemoryLine uses the same least-significant-first convention:
//
//     data[0] -> bits [7:0]
//     data[1] -> bits [15:8]
//     ...
//
// Therefore conversion does not depend on memory endianness.  Endianness
// is handled only when MemoryLine is mapped onto byte addresses.
//==========================================================================

#ifndef MEMORY_INTERFACE_VPI

static MemoryLine dpi_vector_to_memory_line(
    const svBitVecVal *words,
    unsigned line_width)
{
    const unsigned num_bytes =
        line_width / 8u;

    MemoryLine data(
        num_bytes,
        0
    );

    if (words == nullptr)
        return data;

    for (unsigned byte_index = 0;
         byte_index < num_bytes;
         ++byte_index) {

        const unsigned bit_index =
            byte_index * 8u;

        const unsigned word_index =
            bit_index / 32u;

        const unsigned shift =
            bit_index % 32u;

        data[byte_index] =
            static_cast<uint8_t>(
                (words[word_index] >> shift) & 0xffu
            );
    }

    return data;
}


static void memory_line_to_dpi_vector(
    const MemoryLine &data,
    svBitVecVal *words,
    unsigned line_width)
{
    if (words == nullptr)
        return;

    const unsigned num_words =
        (line_width + 31u) / 32u;

    for (unsigned i = 0;
         i < num_words;
         ++i) {

        words[i] = 0;
    }

    const unsigned num_bytes =
        std::min(
            static_cast<unsigned>(data.size()),
            line_width / 8u
        );

    for (unsigned byte_index = 0;
         byte_index < num_bytes;
         ++byte_index) {

        const unsigned bit_index =
            byte_index * 8u;

        const unsigned word_index =
            bit_index / 32u;

        const unsigned shift =
            bit_index % 32u;

        words[word_index] |=
            static_cast<svBitVecVal>(
                data[byte_index]
            ) << shift;
    }
}

#endif


//==========================================================================
// DPI-C interface
//==========================================================================

extern "C" {


int memory_byte_exists(int id, uint64_t address) {
    auto *m=get_memory(id); return m && m->byte_exists(address);
}
int memory_line_exists(int id, uint64_t address, unsigned width, unsigned mode) {
    auto *m=get_memory(id); return m && m->line_exists(address,width,mode);
}
unsigned memory_address_count(int id) {
    auto *m=get_memory(id); return m ? m->stored_addresses().size() : 0;
}
// Enumerated addresses are canonical byte addresses, independent of addressing mode.
#ifndef MEMORY_INTERFACE_VPI
void memory_address_at(int id, unsigned index, svBitVecVal *address) {
    auto *m=get_memory(id); const auto *entries=m ? &m->stored_addresses() : nullptr;
    uint64_t a=entries && index<entries->size() ? (*entries)[index] : 0;
    address[0]=static_cast<uint32_t>(a); address[1]=static_cast<uint32_t>(a>>32);
}
#endif

//--------------------------------------------------------------------------
// memory_clear
//--------------------------------------------------------------------------

void memory_clear(
    int memory_id)
{
    Memory *memory =
        get_memory(memory_id);

    if (memory != nullptr)
        memory->clear();
}


//--------------------------------------------------------------------------
// memory_read_byte
//
// Raw canonical byte access.
//
// byte_address is ALWAYS an internal byte address.
// No endian or ADDRESS_MODE conversion is performed.
//--------------------------------------------------------------------------

unsigned int memory_read_byte(
    int memory_id,
    uint64_t byte_address)
{
    Memory *memory =
        get_memory(memory_id);

    if (memory == nullptr)
        return 0;

    return static_cast<unsigned int>(
        memory->read_byte(
            byte_address
        )
    );
}


//--------------------------------------------------------------------------
// memory_dump_binary
//
// Dump an exact raw byte range:
//
//     [start_byte_address, start_byte_address + size)
//
// No endian conversion.
// No ADDRESS_MODE conversion.
// Missing bytes are written as 0x00.
//--------------------------------------------------------------------------

int memory_dump_binary(
    int memory_id,
    const char *filename,
    uint64_t start_byte_address,
    uint64_t size)
{
    Memory *memory =
        get_memory(memory_id);

    if (memory == nullptr ||
        filename == nullptr)
        return 0;

    return memory->dump_binary(
        filename,
        start_byte_address,
        size
    ) ? 1 : 0;
}


#ifndef MEMORY_INTERFACE_VPI

//--------------------------------------------------------------------------
// memory_read_line
//
// DPI-C packed-vector interface.
// Not compiled for the Icarus/VPI backend.
//--------------------------------------------------------------------------

void memory_read_line(
    int memory_id,
    uint64_t address,
    svBitVecVal *data,
    unsigned int line_width,
    unsigned int little_endian,
    unsigned int address_mode)
{
    if (data == nullptr)
        return;

    const unsigned num_words =
        (line_width + 31u) / 32u;

    for (unsigned i = 0;
         i < num_words;
         ++i) {

        data[i] = 0;
    }

    Memory *memory =
        get_memory(memory_id);

    if (memory == nullptr)
        return;

    const MemoryLine line =
        memory->read_line(
            address,
            line_width,
            little_endian != 0,
            address_mode
        );

    memory_line_to_dpi_vector(
        line,
        data,
        line_width
    );
}


//--------------------------------------------------------------------------
// memory_write_line
//--------------------------------------------------------------------------

void memory_write_line(
    int memory_id,
    uint64_t address,
    const svBitVecVal *data,
    unsigned int line_width,
    unsigned int little_endian,
    unsigned int address_mode)
{
    Memory *memory =
        get_memory(memory_id);

    if (memory == nullptr)
        return;

    memory->write_line(
        address,
        dpi_vector_to_memory_line(
            data,
            line_width
        ),
        line_width,
        little_endian != 0,
        address_mode
    );
}

#endif // !MEMORY_INTERFACE_VPI


//--------------------------------------------------------------------------
// memory_load
//--------------------------------------------------------------------------

int memory_load(
    int memory_id,
    const char *filename,
    unsigned int line_width,
    unsigned int little_endian,
    unsigned int address_mode)
{
    Memory *memory =
        get_memory(memory_id);

    if (memory == nullptr ||
        filename == nullptr)
        return 0;

    return memory->load(
        filename,
        line_width,
        little_endian != 0,
        address_mode
    ) ? 1 : 0;
}


//--------------------------------------------------------------------------
// memory_dump
//--------------------------------------------------------------------------

int memory_dump(
    int memory_id,
    const char *filename,
    unsigned int line_width,
    unsigned int little_endian,
    unsigned int address_mode)
{
    Memory *memory =
        get_memory(memory_id);

    if (memory == nullptr ||
        filename == nullptr)
        return 0;

    return memory->dump(
        filename,
        line_width,
        little_endian != 0,
        address_mode
    ) ? 1 : 0;
}


//--------------------------------------------------------------------------
// memory_compare
//--------------------------------------------------------------------------

double memory_compare(
    int memory_id,
    const char *filename,
    unsigned int line_width,
    unsigned int little_endian,
    unsigned int address_mode)
{
    Memory *memory =
        get_memory(memory_id);

    if (memory == nullptr ||
        filename == nullptr)
        return 0.0;

    return memory->compare(
        filename,
        line_width,
        little_endian != 0,
        address_mode
    );
}


} // extern "C"


#ifdef MEMORY_INTERFACE_VPI

//==========================================================================
// Icarus VPI interface
//
// Returning operations are true VPI system functions:
//
//   data    = $memory_read_line(...);
//   status  = $memory_load(...);
//   status  = $memory_dump(...);
//   percent = $memory_compare(...);
//
// Non-returning operations remain system tasks:
//
//   $memory_write_line(...);
//   $memory_clear(...);
//
// This avoids vpi_put_value() into Icarus automatic-function/task stack
// variables (__vpiVThrVec4Stack).
//==========================================================================


//--------------------------------------------------------------------------
// Argument helpers
//--------------------------------------------------------------------------

static std::vector<vpiHandle> vpi_get_args(
    vpiHandle call_handle)
{
    std::vector<vpiHandle> args;

    vpiHandle iterator =
        vpi_iterate(
            vpiArgument,
            call_handle
        );

    if (iterator == nullptr)
        return args;

    while (vpiHandle arg = vpi_scan(iterator))
        args.push_back(arg);

    return args;
}


static int32_t vpi_get_int32(
    vpiHandle handle)
{
    s_vpi_value value;
    value.format = vpiIntVal;

    vpi_get_value(
        handle,
        &value
    );

    return static_cast<int32_t>(
        value.value.integer
    );
}


static uint64_t vpi_get_uint64(
    vpiHandle handle)
{
    s_vpi_value value;
    value.format = vpiVectorVal;

    vpi_get_value(
        handle,
        &value
    );

    const s_vpi_vecval *vec =
        value.value.vector;

    if (vec == nullptr)
        return 0;

    uint64_t result =
        static_cast<uint32_t>(
            vec[0].aval
        );

    const int width =
        vpi_get(
            vpiSize,
            handle
        );

    if (width > 32) {
        result |=
            static_cast<uint64_t>(
                static_cast<uint32_t>(
                    vec[1].aval
                )
            ) << 32;
    }

    return result;
}


static std::vector<s_vpi_vecval> vpi_get_vector(
    vpiHandle handle,
    unsigned width)
{
    const unsigned words =
        (width + 31u) / 32u;

    std::vector<s_vpi_vecval> result(words);

    for (auto &word : result) {
        word.aval = 0;
        word.bval = 0;
    }

    s_vpi_value value;
    value.format = vpiVectorVal;

    vpi_get_value(
        handle,
        &value
    );

    if (value.value.vector == nullptr)
        return result;

    const int source_width =
        vpi_get(
            vpiSize,
            handle
        );

    const unsigned source_words =
        source_width > 0
            ? (static_cast<unsigned>(source_width) + 31u) / 32u
            : 0u;

    const unsigned copy_words =
        std::min(
            words,
            source_words
        );

    for (unsigned i = 0; i < copy_words; ++i) {
        result[i].aval =
            value.value.vector[i].aval;

        result[i].bval =
            value.value.vector[i].bval;
    }

    return result;
}


static void vpi_put_vector(
    vpiHandle handle,
    const std::vector<s_vpi_vecval> &vec)
{
    s_vpi_value value;
    value.format = vpiVectorVal;

    value.value.vector =
        const_cast<s_vpi_vecval *>(
            vec.data()
        );

    vpi_put_value(
        handle,
        &value,
        nullptr,
        vpiNoDelay
    );
}


static std::vector<uint8_t> vpi_vector_to_bytes(
    const std::vector<s_vpi_vecval> &vec,
    unsigned width)
{
    const unsigned num_bytes =
        (width + 7u) / 8u;

    std::vector<uint8_t> bytes(
        num_bytes,
        0
    );

    for (unsigned byte_index = 0;
         byte_index < num_bytes;
         ++byte_index) {

        const unsigned bit_index =
            byte_index * 8u;

        const unsigned word_index =
            bit_index / 32u;

        const unsigned shift =
            bit_index % 32u;

        uint32_t word = 0;

        if (word_index < vec.size()) {
            word =
                static_cast<uint32_t>(
                    vec[word_index].aval
                );
        }

        bytes[byte_index] =
            static_cast<uint8_t>(
                (word >> shift) & 0xffu
            );
    }

    return bytes;
}


static std::vector<s_vpi_vecval> bytes_to_vpi_vector(
    const std::vector<uint8_t> &bytes,
    unsigned width)
{
    const unsigned words =
        (width + 31u) / 32u;

    std::vector<s_vpi_vecval> vec(words);

    for (auto &word : vec) {
        word.aval = 0;
        word.bval = 0;
    }

    for (unsigned byte_index = 0;
         byte_index < bytes.size();
         ++byte_index) {

        const unsigned bit_index =
            byte_index * 8u;

        const unsigned word_index =
            bit_index / 32u;

        const unsigned shift =
            bit_index % 32u;

        if (word_index >= vec.size())
            break;

        const uint32_t byte_value =
            static_cast<uint32_t>(
                bytes[byte_index]
            );

        vec[word_index].aval |=
            static_cast<PLI_INT32>(
                byte_value << shift
            );
    }

    return vec;
}


static std::string vpi_get_string(
    vpiHandle handle)
{
    s_vpi_value value;
    value.format = vpiStringVal;

    vpi_get_value(
        handle,
        &value
    );

    if (value.value.str == nullptr)
        return std::string();

    return std::string(
        value.value.str
    );
}


//--------------------------------------------------------------------------
// Put a value onto the VPI system-function call handle.
//--------------------------------------------------------------------------

static void vpi_return_int32(
    vpiHandle call_handle,
    int32_t data)
{
    s_vpi_value value;
    value.format = vpiIntVal;
    value.value.integer =
        static_cast<PLI_INT32>(data);

    vpi_put_value(
        call_handle,
        &value,
        nullptr,
        vpiNoDelay
    );
}




//==========================================================================
// $memory_read_line(
//     memory_id,
//     address,
//     data_out,
//     width,
//     endian,
//     address_mode
// )
//
// Icarus VPI read path.
//
// IMPORTANT:
//
// The memory DATA crosses the VPI boundary as a packed vector through the
// explicit data_out argument.  It is not returned as a 64-bit VPI system
// function value.
//==========================================================================

static PLI_INT32 vpi_memory_read_line(
    PLI_BYTE8 *)
{
    vpiHandle call_handle =
        vpi_handle(
            vpiSysTfCall,
            nullptr
        );

    const auto args =
        vpi_get_args(call_handle);

    if (args.size() != 6) {
        vpi_printf(
            "ERROR::[memory-vpi] "
            "$memory_read_line expects 6 arguments, got %zu\n",
            args.size()
        );

        return 0;
    }

    const int memory_id =
        vpi_get_int32(args[0]);

    const uint64_t address =
        vpi_get_uint64(args[1]);

    vpiHandle data_handle =
        args[2];

    const unsigned line_width =
        static_cast<unsigned>(
            vpi_get_int32(args[3])
        );

    const unsigned little_endian =
        static_cast<unsigned>(
            vpi_get_int32(args[4])
        );

    const unsigned address_mode =
        static_cast<unsigned>(
            vpi_get_int32(args[5])
        );

    Memory *memory =
        get_memory(memory_id);

    if (memory == nullptr)
        return 0;

    const MemoryLine data =
        memory->read_line(
            address,
            line_width,
            little_endian != 0,
            address_mode
        );

    const auto vec =
        bytes_to_vpi_vector(
            data,
            line_width
        );

    vpi_put_vector(
        data_handle,
        vec
    );

    return 0;
}


//==========================================================================
// $memory_write_line(memory_id, address, data, width, endian, address_mode)
//==========================================================================

static PLI_INT32 vpi_memory_write_line(
    PLI_BYTE8 *)
{
    vpiHandle call_handle =
        vpi_handle(
            vpiSysTfCall,
            nullptr
        );

    const auto args =
        vpi_get_args(call_handle);

    if (args.size() != 6) {
        vpi_printf(
            "ERROR::[memory-vpi] "
            "$memory_write_line expects 6 arguments, got %zu\n",
            args.size()
        );

        return 0;
    }

    const int memory_id =
        vpi_get_int32(args[0]);

    const uint64_t address =
        vpi_get_uint64(args[1]);

    const unsigned line_width =
        static_cast<unsigned>(
            vpi_get_int32(args[3])
        );

    const unsigned little_endian =
        static_cast<unsigned>(
            vpi_get_int32(args[4])
        );

    const unsigned address_mode =
        static_cast<unsigned>(
            vpi_get_int32(args[5])
        );

    const auto vec =
        vpi_get_vector(
            args[2],
            line_width
        );

    const MemoryLine data =
        vpi_vector_to_bytes(
            vec,
            line_width
        );

    Memory *memory =
        get_memory(memory_id);

    if (memory == nullptr)
        return 0;

    memory->write_line(
        address,
        data,
        line_width,
        little_endian != 0,
        address_mode
    );

    return 0;
}


//==========================================================================
// $memory_clear(memory_id)
//==========================================================================

static PLI_INT32 vpi_memory_clear(
    PLI_BYTE8 *)
{
    vpiHandle call_handle =
        vpi_handle(
            vpiSysTfCall,
            nullptr
        );

    const auto args =
        vpi_get_args(call_handle);

    if (args.size() != 1) {
        vpi_printf(
            "ERROR::[memory-vpi] "
            "$memory_clear expects 1 argument, got %zu\n",
            args.size()
        );
        return 0;
    }

    memory_clear(
        vpi_get_int32(args[0])
    );

    return 0;
}


//==========================================================================
// $memory_load(memory_id, filename, width, endian, address_mode)
//==========================================================================

static PLI_INT32 vpi_memory_load(
    PLI_BYTE8 *)
{
    vpiHandle call_handle =
        vpi_handle(
            vpiSysTfCall,
            nullptr
        );

    const auto args =
        vpi_get_args(call_handle);

    if (args.size() != 5) {
        vpi_printf(
            "ERROR::[memory-vpi] "
            "$memory_load expects 5 arguments, got %zu\n",
            args.size()
        );

        vpi_return_int32(
            call_handle,
            0
        );

        return 0;
    }

    const int arg_memory_id =
        vpi_get_int32(args[0]);

    const std::string arg_filename =
        vpi_get_string(args[1]);

    const int arg_line_width =
        vpi_get_int32(args[2]);

    const int arg_little_endian =
        vpi_get_int32(args[3]);

    const int arg_address_mode =
        vpi_get_int32(args[4]);

    const int status =
        memory_load(
            arg_memory_id,
            arg_filename.c_str(),
            static_cast<unsigned>(arg_line_width),
            static_cast<unsigned>(arg_little_endian),
            static_cast<unsigned>(arg_address_mode)
        );

    vpi_return_int32(
        call_handle,
        status
    );

    return 0;
}


//==========================================================================
// $memory_dump(memory_id, filename, width, endian, address_mode)
//==========================================================================

static PLI_INT32 vpi_memory_dump(
    PLI_BYTE8 *)
{
    vpiHandle call_handle =
        vpi_handle(
            vpiSysTfCall,
            nullptr
        );

    const auto args =
        vpi_get_args(call_handle);

    if (args.size() != 5) {
        vpi_printf(
            "ERROR::[memory-vpi] "
            "$memory_dump expects 5 arguments, got %zu\n",
            args.size()
        );

        vpi_return_int32(
            call_handle,
            0
        );

        return 0;
    }

    const int status =
        memory_dump(
            vpi_get_int32(args[0]),
            vpi_get_string(args[1]).c_str(),
            static_cast<unsigned>(
                vpi_get_int32(args[2])
            ),
            static_cast<unsigned>(
                vpi_get_int32(args[3])
            ),
            static_cast<unsigned>(
                vpi_get_int32(args[4])
            )
        );

    vpi_return_int32(
        call_handle,
        status
    );

    return 0;
}


//==========================================================================
// $memory_compare(memory_id, filename, width, endian, address_mode)
//==========================================================================

static PLI_INT32 vpi_memory_compare(
    PLI_BYTE8 *)
{
    vpiHandle call_handle =
        vpi_handle(
            vpiSysTfCall,
            nullptr
        );

    const auto args =
        vpi_get_args(call_handle);

    if (args.size() != 5) {
        vpi_printf(
            "ERROR::[memory-vpi] "
            "$memory_compare expects 5 arguments, got %zu\n",
            args.size()
        );

        vpi_return_int32(
            call_handle,
            0
        );

        return 0;
    }

    const double percentage =
        memory_compare(
            vpi_get_int32(args[0]),
            vpi_get_string(args[1]).c_str(),
            static_cast<unsigned>(
                vpi_get_int32(args[2])
            ),
            static_cast<unsigned>(
                vpi_get_int32(args[3])
            ),
            static_cast<unsigned>(
                vpi_get_int32(args[4])
            )
        );

    // Icarus has compatibility problems returning vpiRealVal from
    // user-defined VPI system functions.  The testbench only requires
    // a percentage in the range 0..100, so return the rounded integer
    // percentage instead.
    const int32_t percentage_int =
        static_cast<int32_t>(
            percentage + 0.5
        );

    vpi_return_int32(
        call_handle,
        percentage_int
    );

    return 0;
}


//==========================================================================
// Registration
//==========================================================================

static void register_vpi_task(
    const char *name,
    PLI_INT32 (*calltf)(PLI_BYTE8 *))
{
    s_vpi_systf_data tf;
    tf.type        = vpiSysTask;
    tf.sysfunctype = 0;
    tf.tfname      = const_cast<PLI_BYTE8 *>(name);
    tf.calltf      = calltf;
    tf.compiletf   = nullptr;
    tf.sizetf      = nullptr;
    tf.user_data   = nullptr;

    vpi_register_systf(&tf);
}


static void register_vpi_int_function(
    const char *name,
    PLI_INT32 (*calltf)(PLI_BYTE8 *))
{
    s_vpi_systf_data tf;
    tf.type        = vpiSysFunc;
    tf.sysfunctype = vpiIntFunc;
    tf.tfname      = const_cast<PLI_BYTE8 *>(name);
    tf.calltf      = calltf;
    tf.compiletf   = nullptr;
    tf.sizetf      = nullptr;
    tf.user_data   = nullptr;

    vpi_register_systf(&tf);
}




static PLI_INT32 vpi_memory_byte_exists(PLI_BYTE8 *) {
    auto call=vpi_handle(vpiSysTfCall,nullptr); auto a=vpi_get_args(call);
    if(a.size()!=2) { vpi_printf("memory_byte_exists needs 2 arguments\n"); vpi_control(vpiFinish,1); return 0; }
    vpi_return_int32(call,memory_byte_exists(vpi_get_int32(a[0]),vpi_get_uint64(a[1]))); return 0;
}
static PLI_INT32 vpi_memory_line_exists(PLI_BYTE8 *) {
    auto call=vpi_handle(vpiSysTfCall,nullptr); auto a=vpi_get_args(call);
    if(a.size()!=4) { vpi_printf("memory_line_exists needs 4 arguments\n"); vpi_control(vpiFinish,1); return 0; }
    vpi_return_int32(call,memory_line_exists(vpi_get_int32(a[0]),vpi_get_uint64(a[1]),vpi_get_int32(a[2]),vpi_get_int32(a[3]))); return 0;
}
static PLI_INT32 vpi_memory_address_count(PLI_BYTE8 *) {
    auto call=vpi_handle(vpiSysTfCall,nullptr); auto a=vpi_get_args(call);
    if(a.size()!=1) { vpi_control(vpiFinish,1); return 0; }
    vpi_return_int32(call,memory_address_count(vpi_get_int32(a[0]))); return 0;
}
static PLI_INT32 vpi_memory_address_at(PLI_BYTE8 *) {
    auto call=vpi_handle(vpiSysTfCall,nullptr); auto a=vpi_get_args(call);
    if(a.size()!=3) { vpi_control(vpiFinish,1); return 0; }
    auto *m=get_memory(vpi_get_int32(a[0])); const auto *entries=m ? &m->stored_addresses() : nullptr;
    unsigned index=vpi_get_int32(a[1]); uint64_t address=entries && index<entries->size() ? (*entries)[index] : 0;
    std::vector<s_vpi_vecval> vec(2); vec[0].aval=address; vec[1].aval=address>>32;
    vpi_put_vector(a[2],vec); return 0;
}

#ifndef MEMORY_ONLY
void register_cnn_vpi();
#endif
static void register_memory_vpi()
{
#ifndef MEMORY_ONLY
    register_cnn_vpi();
#endif
    register_vpi_int_function("$memory_byte_exists",vpi_memory_byte_exists);
    register_vpi_int_function("$memory_line_exists",vpi_memory_line_exists);
    register_vpi_int_function("$memory_address_count",vpi_memory_address_count);
    register_vpi_task("$memory_address_at",vpi_memory_address_at);
    // Functions with return values.
    register_vpi_int_function(
        "$memory_load",
        vpi_memory_load
    );

    register_vpi_int_function(
        "$memory_dump",
        vpi_memory_dump
    );

    register_vpi_int_function(
        "$memory_compare",
        vpi_memory_compare
    );

    // Tasks with no return value.
    register_vpi_task(
        "$memory_read_line",
        vpi_memory_read_line
    );

    register_vpi_task(
        "$memory_write_line",
        vpi_memory_write_line
    );

    register_vpi_task(
        "$memory_clear",
        vpi_memory_clear
    );
}


extern "C" {

void (*vlog_startup_routines[])() = {
    register_memory_vpi,
    nullptr
};

} // extern "C"

#endif // MEMORY_INTERFACE_VPI
