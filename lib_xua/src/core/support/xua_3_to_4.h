    // int *xua_4_to_3(int *output, int *input, int count)
    // r0: argument 1, output (word aligned)
    // r1: argument 2, input  (word aligned)
    // r2: argument 3, count  (number of 3-byte chunks to write, must be > 0)
    // Returns pointer beyond last word that was written.

/**
 * Function that takes packed 24-bit numbers and stores them as an array of integers
 * Numbers are stored left aligned and zero padded in the lower bits
 *
 * \param  output   output array - must be N integers long, will contain N aligned ints
 * \param  input    input array - must be 3*N bytes long and word aligned
 * \param  N        number of 3-byte values to unpack
 *
 * \returns output + N
 */
extern int* xua_4_to_3(int *output, int *input, int N);

/**
 * Function that takes an array of integers and stores them as packed 24-bit numbers.
 * Numbers are shifted to the right before storing.
 * Note that the output must be an array of words, and that it will overwrite the last
 * word completely, even though it may only hold 1, 2, or 3 bytes.
 *
 * \param  output   output array - must be (3*N + 3)/4 integers long, and word aligned
 *                  will contain N triplets of bytes
 * \param  input    input array - must be N words long
 * \param  N        number of 3-byte values to pack
 *
 * \returns output + (3*N+3)/4
 */
extern int* xua_3_to_4(int *output, int *input, int N);
