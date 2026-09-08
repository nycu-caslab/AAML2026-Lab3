import argparse
import math
import random
import secrets
import struct
import sys
import time

import serial
from serial.tools import list_ports


BAUD_RATE = 115200
READ_TIMEOUT_SEC = 0.1
WRITE_TIMEOUT_SEC = 10.0
RESULT_TIMEOUT_SEC = 30.0

FPGA_VID = 0x0403
FPGA_PID = 0x6010

# These values must match TPU_top and uart_controller.
MEMORY_DEPTH = 1024
LANES_PER_WORD = 4
MIN_MATRIX_DIMENSION = 2
MIN_VECTOR_DIMENSION = 1
MAX_DIMENSION = 254

# Modest finite values exercise FP32 rounding without generating NaN, infinity,
# overflow, or subnormal corner cases.
RANDOM_VALUE_MIN = -4.0
RANDOM_VALUE_MAX = 4.0

# Permit a difference in the last one or two FP32 representation steps.
DEFAULT_MAX_ULP = 2

FIXED_GEMV_CASES = (
    (4, 4, 1),
    (8, 8, 1),
    (35, 41, 1),
    (29, 51, 1),
)


def float32_to_bits(value):
    return struct.unpack("<I", struct.pack("<f", float(value)))[0]


def bits_to_float32(bits):
    return struct.unpack("<f", struct.pack("<I", bits & 0xFFFFFFFF))[0]


def to_float32(value):
    return bits_to_float32(float32_to_bits(value))


def pack_fp32(value):
    return struct.pack("<I", float32_to_bits(value))


def round_right_shift_to_even(value, shift):
    """Round a nonnegative integer right shift using nearest, ties to even."""
    if shift <= 0:
        return value << (-shift)

    quotient, remainder = divmod(value, 1 << shift)
    halfway = 1 << (shift - 1)

    if remainder > halfway:
        quotient += 1
    elif remainder == halfway and (quotient & 1):
        quotient += 1

    return quotient


def decode_finite_fp32(bits):
    """Return (signed significand, exponent) for value = sig * 2**exp."""
    sign = -1 if (bits & 0x80000000) else 1
    exponent_field = (bits >> 23) & 0xFF
    fraction = bits & 0x7FFFFF

    if exponent_field == 0xFF:
        raise ValueError("NaN and infinity are not supported by this test")

    if exponent_field == 0:
        significand = fraction
        exponent = -149
    else:
        significand = (1 << 23) | fraction
        exponent = exponent_field - 127 - 23

    return sign * significand, exponent


def exact_binary_to_fp32_bits(signed_integer, binary_exponent):
    """Round signed_integer * 2**binary_exponent to IEEE-754 binary32."""
    if signed_integer == 0:
        return 0x00000000

    sign_bit = 0x80000000 if signed_integer < 0 else 0
    magnitude = abs(signed_integer)
    highest_bit = magnitude.bit_length() - 1
    unbiased_exponent = highest_bit + binary_exponent

    if unbiased_exponent > 127:
        return sign_bit | 0x7F800000

    if unbiased_exponent >= -126:
        shift = highest_bit - 23
        significand = round_right_shift_to_even(magnitude, shift)

        if significand >= (1 << 24):
            significand >>= 1
            unbiased_exponent += 1
            if unbiased_exponent > 127:
                return sign_bit | 0x7F800000

        exponent_field = unbiased_exponent + 127
        fraction = significand - (1 << 23)
        return sign_bit | (exponent_field << 23) | (fraction & 0x7FFFFF)

    # Subnormal result uses units of 2^-149.
    shift = -(binary_exponent + 149)
    fraction = round_right_shift_to_even(magnitude, shift)

    if fraction == 0:
        return sign_bit
    if fraction >= (1 << 23):
        return sign_bit | (1 << 23)
    return sign_bit | fraction


def fp32_fma_bits(a_bits, b_bits, c_bits):
    """
    Bit-level emulation of one PE operation: round_fp32(a*b + c).

    Golden generation does not use Python floating-point multiplication or
    addition. It uses exact integer operations on IEEE-754 significands and
    performs one round-to-nearest-even conversion, like a fused FP32 FMA.
    """
    a_significand, a_exponent = decode_finite_fp32(a_bits)
    b_significand, b_exponent = decode_finite_fp32(b_bits)
    c_significand, c_exponent = decode_finite_fp32(c_bits)

    product_significand = a_significand * b_significand
    product_exponent = a_exponent + b_exponent

    if product_significand == 0:
        return c_bits
    if c_significand == 0:
        return exact_binary_to_fp32_bits(product_significand, product_exponent)

    common_exponent = min(product_exponent, c_exponent)
    exact_sum = (
        (product_significand << (product_exponent - common_exponent))
        + (c_significand << (c_exponent - common_exponent))
    )
    return exact_binary_to_fp32_bits(exact_sum, common_exponent)


def hardware_gemm_golden_bits(a_matrix, b_matrix):
    """Emulate every PE's K-ordered FP32 FMA accumulation."""
    m_value = len(a_matrix)
    k_value = len(a_matrix[0])
    n_value = len(b_matrix[0])

    a_bits = [[float32_to_bits(value) for value in row] for row in a_matrix]
    b_bits = [[float32_to_bits(value) for value in row] for row in b_matrix]
    result_bits = [
        [0x00000000 for _ in range(n_value)]
        for _ in range(m_value)
    ]

    for row in range(m_value):
        for column in range(n_value):
            accumulator_bits = 0x00000000
            for k_index in range(k_value):
                accumulator_bits = fp32_fma_bits(
                    a_bits[row][k_index],
                    b_bits[k_index][column],
                    accumulator_bits,
                )
            result_bits[row][column] = accumulator_bits

    return result_bits


def bits_matrix_to_float(matrix_bits):
    return [[bits_to_float32(bits) for bits in row] for row in matrix_bits]


def bram_word_counts(m_value, k_value, n_value):
    a_word_count = math.ceil(m_value / LANES_PER_WORD) * k_value
    b_word_count = math.ceil(n_value / LANES_PER_WORD) * k_value
    c_word_count = math.ceil(n_value / LANES_PER_WORD) * m_value
    return a_word_count, b_word_count, c_word_count


def dimensions_fit_hardware(m_value, k_value, n_value):
    if not (
        MIN_MATRIX_DIMENSION <= m_value <= MAX_DIMENSION
        and MIN_MATRIX_DIMENSION <= k_value <= MAX_DIMENSION
        and MIN_VECTOR_DIMENSION <= n_value <= MAX_DIMENSION
    ):
        return False
    return max(bram_word_counts(m_value, k_value, n_value)) <= MEMORY_DEPTH


def generate_random_matrix(generator, rows, columns, minimum, maximum):
    matrix = []
    for _ in range(rows):
        matrix_row = []
        for _ in range(columns):
            # Quantize now so FPGA input, displayed input, and Golden all use
            # exactly the same transmitted binary32 value.
            matrix_row.append(to_float32(generator.uniform(minimum, maximum)))
        matrix.append(matrix_row)
    return matrix


def find_fpga_uart():
    matches = []

    print("=" * 72)
    print("Searching for Arty A7 UART")
    print("=" * 72)

    for port in list_ports.comports():
        if port.vid == FPGA_VID and port.pid == FPGA_PID:
            matches.append(port)

            print(f"Candidate   : {port.device}")
            print(f"Description : {port.description}")
            print(f"Interface   : {port.interface}")
            print(f"Location    : {port.location}")
            print()

    if not matches:
        print("Arty A7 UART not found.")
        return None

    if len(matches) == 1:
        return matches[0].device

    # Arty UART uses FTDI Interface B.
    for port in matches:
        interface_text = (port.interface or "").upper()
        description_text = (port.description or "").upper()
        location_text = port.location or ""

        if (
            "INTERFACE B" in interface_text
            or "CONVERTER B" in description_text
            or location_text.endswith(":1.1")
        ):
            print(f"Selecting FTDI Interface B: {port.device}")
            return port.device

    selected = sorted(matches, key=lambda item: item.device)[-1].device
    print(f"Unable to identify Interface B; selecting: {selected}")
    print("Use --port to override this selection if necessary.")
    return selected


def open_uart(port_name):
    return serial.Serial(
        port=port_name,
        baudrate=BAUD_RATE,
        bytesize=serial.EIGHTBITS,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        timeout=READ_TIMEOUT_SEC,
        write_timeout=WRITE_TIMEOUT_SEC,
    )


def validate_matrix(matrix, name):
    if not matrix or not matrix[0]:
        raise ValueError(f"{name} must not be empty")
    column_count = len(matrix[0])
    if any(len(row) != column_count for row in matrix):
        raise ValueError(f"{name} must be rectangular")


def check_dimensions(a_matrix, b_matrix):
    validate_matrix(a_matrix, "A")
    validate_matrix(b_matrix, "B")
    m_value = len(a_matrix)
    k_value = len(a_matrix[0])
    b_rows = len(b_matrix)
    n_value = len(b_matrix[0])

    if k_value != b_rows:
        raise ValueError(
            f"Dimension mismatch: A is {m_value}x{k_value}, "
            f"but B is {b_rows}x{n_value}"
        )

    if not dimensions_fit_hardware(m_value, k_value, n_value):
        a_words, b_words, c_words = bram_word_counts(
            m_value, k_value, n_value
        )
        raise ValueError(
            "Dimensions exceed TPU register or BRAM limits: "
            f"M={m_value}, K={k_value}, N={n_value}, "
            f"A words={a_words}, B words={b_words}, C words={c_words}"
        )
    return m_value, k_value, n_value


def build_request_packet(a_matrix, b_matrix):
    m_value, k_value, n_value = check_dimensions(a_matrix, b_matrix)
    packet = bytearray([k_value, m_value, n_value])

    # A BRAM address = m_block*K + k.
    for m_block in range(math.ceil(m_value / LANES_PER_WORD)):
        for k_index in range(k_value):
            for lane in range(LANES_PER_WORD):
                row = m_block * LANES_PER_WORD + lane
                value = a_matrix[row][k_index] if row < m_value else 0.0
                packet.extend(pack_fp32(value))

    # B BRAM address = n_block*K + k.
    for n_block in range(math.ceil(n_value / LANES_PER_WORD)):
        for k_index in range(k_value):
            for lane in range(LANES_PER_WORD):
                column = n_block * LANES_PER_WORD + lane
                value = b_matrix[k_index][column] if column < n_value else 0.0
                packet.extend(pack_fp32(value))

    return bytes(packet), m_value, k_value, n_value


def expected_response_size(m_value, n_value):
    c_word_count = m_value * math.ceil(n_value / LANES_PER_WORD)
    return c_word_count * LANES_PER_WORD * 4


def read_exact(ser, byte_count, timeout_sec):
    result = bytearray()
    deadline = time.monotonic() + timeout_sec
    while len(result) < byte_count and time.monotonic() < deadline:
        chunk = ser.read(byte_count - len(result))
        if chunk:
            result.extend(chunk)
    return bytes(result)


def unpack_c_matrix_bits(received, m_value, n_value):
    n_blocks = math.ceil(n_value / LANES_PER_WORD)
    expected_bytes = expected_response_size(m_value, n_value)
    if len(received) != expected_bytes:
        raise ValueError(
            f"Expected {expected_bytes} result bytes, received {len(received)}"
        )

    flat_bits = struct.unpack(f"<{expected_bytes // 4}I", received)
    c_bits = [
        [0x00000000 for _ in range(n_value)]
        for _ in range(m_value)
    ]
    value_index = 0

    # TPU C BRAM address = n_block*M + row.
    for n_block in range(n_blocks):
        for row in range(m_value):
            for lane in range(LANES_PER_WORD):
                column = n_block * LANES_PER_WORD + lane
                value_bits = flat_bits[value_index]
                value_index += 1
                if column < n_value:
                    c_bits[row][column] = value_bits
    return c_bits


def ordered_float32_bits(bits):
    """Map binary32 bits to a monotonic integer for ULP distance."""
    if bits & 0x80000000:
        return 0x80000000 - (bits & 0x7FFFFFFF)
    return 0x80000000 + bits


def ulp_distance(a_bits, b_bits):
    a_exponent = (a_bits >> 23) & 0xFF
    b_exponent = (b_bits >> 23) & 0xFF
    a_fraction = a_bits & 0x7FFFFF
    b_fraction = b_bits & 0x7FFFFF

    if (a_exponent == 0xFF and a_fraction != 0) or (
        b_exponent == 0xFF and b_fraction != 0
    ):
        return None
    return abs(ordered_float32_bits(a_bits) - ordered_float32_bits(b_bits))


def compare_result_bits(actual_bits, expected_bits, max_ulp):
    mismatches = []
    maximum_observed_ulp = 0
    for row in range(len(expected_bits)):
        for column in range(len(expected_bits[0])):
            distance = ulp_distance(
                actual_bits[row][column], expected_bits[row][column]
            )
            if distance is None or distance > max_ulp:
                mismatches.append(
                    (
                        row,
                        column,
                        actual_bits[row][column],
                        expected_bits[row][column],
                        distance,
                    )
                )
            elif distance > maximum_observed_ulp:
                maximum_observed_ulp = distance
    return mismatches, maximum_observed_ulp


def print_matrix(name, matrix):
    print(f"{name} =")
    for row in matrix:
        print("  " + " ".join(f"{value:12.6f}" for value in row))
    print()


def print_matrix_preview(name, matrix, rows=4, columns=8):
    shown_rows = min(rows, len(matrix))
    shown_columns = min(columns, len(matrix[0]))
    print(f"{name} preview ({shown_rows}x{shown_columns}) =")
    for row in range(shown_rows):
        print(
            "  "
            + " ".join(
                f"{matrix[row][column]:12.6f}"
                for column in range(shown_columns)
            )
        )
    print()


def run_gemm_test(
    port_name,
    a_matrix,
    b_matrix,
    seed,
    max_ulp,
    print_all_matrices,
    test_name,
    wait_for_button=True,
):
    packet, m_value, k_value, n_value = build_request_packet(
        a_matrix, b_matrix
    )
    response_size = expected_response_size(m_value, n_value)
    a_words, b_words, c_words = bram_word_counts(m_value, k_value, n_value)

    print("Computing bit-accurate FP32 FMA Golden result...")
    golden_bits = hardware_gemm_golden_bits(a_matrix, b_matrix)
    golden_matrix = bits_matrix_to_float(golden_bits)

    print("=" * 72)
    print(f"{test_name}: TPU UART FP32 GEMV test")
    print("=" * 72)
    print(f"Port              : {port_name}")
    print(f"Baud rate         : {BAUD_RATE}")
    print(f"Random seed       : {seed}")
    print(f"Dimensions        : M={m_value}, K={k_value}, N={n_value}")
    print(f"TPU FMA count     : {m_value * k_value * n_value}")
    print(f"BRAM words        : A={a_words}, B={b_words}, C={c_words}")
    print(f"Request bytes     : {len(packet)}")
    print(f"Expected RX bytes : {response_size}")
    print(f"Allowed error     : {max_ulp} ULP")
    print()

    if print_all_matrices or max(m_value, k_value, n_value) <= 16:
        print_matrix("Input A", a_matrix)
        print_matrix("Input B", b_matrix)
    else:
        print_matrix_preview("Input A", a_matrix)
        print_matrix_preview("Input B", b_matrix)

    try:
        with open_uart(port_name) as ser:
            time.sleep(0.1)
            ser.reset_input_buffer()
            ser.reset_output_buffer()

            if wait_for_button:
                input(
                    f"{test_name}: press BTN1 once to enter UART load mode, then press "
                    "Enter here..."
                )

            ser.reset_input_buffer()
            print("Sending K, M, N, matrix A and matrix B...")
            written = ser.write(packet)
            ser.flush()

            if written != len(packet):
                print(f"FAIL: wrote {written} of {len(packet)} bytes.")
                return False

            print("Waiting for matrix C...")
            received = read_exact(ser, response_size, RESULT_TIMEOUT_SEC)

    except (
        serial.SerialException,
        serial.SerialTimeoutException,
        OSError,
    ) as error:
        print(f"FAIL: serial error: {error}")
        return False

    if len(received) != response_size:
        print(
            f"FAIL: received {len(received)} of {response_size} expected bytes."
        )
        if received:
            print(f"Partial RX: {received[:64].hex(' ')}")
        print("Check BTN1, selected UART port, baud rate, reset and bitstream.")
        return False

    actual_bits = unpack_c_matrix_bits(received, m_value, n_value)
    actual_matrix = bits_matrix_to_float(actual_bits)
    mismatches, maximum_observed_ulp = compare_result_bits(
        actual_bits, golden_bits, max_ulp
    )

    if print_all_matrices or max(m_value, n_value) <= 16:
        print_matrix("FPGA C", actual_matrix)
        print_matrix("Hardware-rule Golden C", golden_matrix)
    else:
        print_matrix_preview("FPGA C", actual_matrix)
        print_matrix_preview("Hardware-rule Golden C", golden_matrix)

    if mismatches:
        print(f"FAIL: {len(mismatches)} matrix element(s) exceeded tolerance.")
        for row, column, actual, expected, distance in mismatches[:20]:
            distance_text = "NaN" if distance is None else str(distance)
            print(
                f"  C[{row}][{column}]: "
                f"FPGA={bits_to_float32(actual):.9g} (0x{actual:08X}), "
                f"Golden={bits_to_float32(expected):.9g} "
                f"(0x{expected:08X}), ULP={distance_text}"
            )
        return False

    # print("PASS: UART -> BRAM -> TPU -> BRAM -> UART random GEMM passed.")
    print("==============================================================")
    print("**                                                          **")
    print("**                                                          **")
    print("**                                                          **")
    print("**                         PASS                             **")
    print("**                                                          **")
    print("**                                                          **")
    print("**                                                          **")
    print("==============================================================")
    return True


def parse_arguments():
    parser = argparse.ArgumentParser(
        description=(
            "Generate fixed-size register/BRAM-valid FP32 GEMV cases and test the "
            "Arty A7 TPU through UART."
        )
    )
    parser.add_argument(
        "--port",
        help="Serial port override, for example COM5 or /dev/ttyUSB1",
    )
    parser.add_argument(
        "--seed",
        type=int,
        help="Random seed for matrix/vector values; omit to generate a new seed",
    )
    parser.add_argument(
        "--max-ulp",
        type=int,
        default=DEFAULT_MAX_ULP,
        help=f"Allowed FP32 ULP difference (default: {DEFAULT_MAX_ULP})",
    )
    parser.add_argument(
        "--print-matrices",
        action="store_true",
        help="Print complete matrices even when dimensions exceed 16",
    )
    parser.add_argument(
        "--no-button-wait",
        action="store_true",
        help="Send immediately without waiting for the BTN1 prompt",
    )
    return parser.parse_args()


def main():
    args = parse_arguments()
    if args.max_ulp < 0:
        print("--max-ulp must not be negative.")
        sys.exit(1)

    seed = args.seed if args.seed is not None else secrets.randbits(64)
    generator = random.Random(seed)

    port_name = args.port or find_fpga_uart()
    if port_name is None:
        print()
        print("Unable to find the Arty A7 UART.")
        print("Use --port COMx or --port /dev/ttyUSB1 if auto-detection fails.")
        sys.exit(1)

    all_passed = True
    for case_index, (m_value, k_value, n_value) in enumerate(FIXED_GEMV_CASES, start=1):
        if not dimensions_fit_hardware(m_value, k_value, n_value):
            print(
                "Unable to generate testcase: "
                f"M={m_value}, K={k_value}, N={n_value} exceeds hardware limits."
            )
            sys.exit(1)

        a_matrix = generate_random_matrix(
            generator,
            m_value,
            k_value,
            RANDOM_VALUE_MIN,
            RANDOM_VALUE_MAX,
        )
        b_matrix = generate_random_matrix(
            generator,
            k_value,
            n_value,
            RANDOM_VALUE_MIN,
            RANDOM_VALUE_MAX,
        )

        test_name = f"Case {case_index} ({m_value}x{k_value} matrix, {k_value}x1 vector)"
        success = run_gemm_test(
            port_name,
            a_matrix,
            b_matrix,
            seed,
            args.max_ulp,
            args.print_matrices,
            test_name,
            wait_for_button=not args.no_button_wait,
        )
        all_passed = all_passed and success
        if not success:
            break

    sys.exit(0 if all_passed else 1)


if __name__ == "__main__":
    main()
